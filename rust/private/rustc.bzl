# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("@io_bazel_rules_rust//rust:private/utils.bzl", "relative_path")
load("@io_bazel_rules_rust//rust:private/legacy_cc_starlark_api_shim.bzl", "get_libs_for_static_executable")
load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_LINK_EXECUTABLE_ACTION_NAME",
)
load(
    "@bazel_tools//tools/cpp:toolchain_utils.bzl",
    "find_cpp_toolchain",
)
load("@bazel_skylib//lib:versions.bzl", "versions")
load("@bazel_version//:def.bzl", "BAZEL_VERSION")

CrateInfo = provider(
    fields = {
        "name": "str: The name of this crate.",
        "type": "str: The type of this crate. eg. lib or bin",
        "root": "File: The source File entrypoint to this crate, eg. lib.rs",
        "srcs": "List[File]: All source Files that are part of the crate.",
        "deps": "List[Provider]: This crate's (rust or cc) dependencies' providers.",
        "output": "File: The output File that will be produced, depends on crate type.",
        "edition": "str: The edition of this crate.",
    },
)

DepInfo = provider(
    fields = {
        "direct_crates": "depset[CrateInfo]",
        "transitive_crates": "depset[CrateInfo]",
        "transitive_dylibs": "depset[File]",
        "transitive_staticlibs": "depset[File]",
        "transitive_libs": "List[File]: All transitive dependencies, not filtered by type.",
    },
)

def _get_rustc_env(ctx, toolchain):
    version = ctx.attr.version if hasattr(ctx.attr, "version") else "0.0.0"
    major, minor, patch = version.split(".", 2)
    if "-" in patch:
        patch, pre = patch.split("-", 1)
    else:
        pre = ""
    return {
        "CARGO_PKG_VERSION": version,
        "CARGO_PKG_VERSION_MAJOR": major,
        "CARGO_PKG_VERSION_MINOR": minor,
        "CARGO_PKG_VERSION_PATCH": patch,
        "CARGO_PKG_VERSION_PRE": pre,
        "CARGO_PKG_AUTHORS": "",
        "CARGO_PKG_NAME": ctx.label.name,
        "CARGO_PKG_DESCRIPTION": "",
        "CARGO_PKG_HOMEPAGE": "",
        "CARGO_CFG_TARGET_OS": toolchain.os,
        "CARGO_CFG_TARGET_ARCH": toolchain.target_arch,
    }

def _get_compilation_mode_opts(ctx, toolchain):
    comp_mode = ctx.var["COMPILATION_MODE"]
    if not comp_mode in toolchain.compilation_mode_opts:
        fail("Unrecognized compilation mode {} for toolchain.".format(comp_mode))

    return toolchain.compilation_mode_opts[comp_mode]

def get_lib_name(lib):
    """Returns the name of a library artifact, eg. libabc.a -> abc"""
    libname, ext = lib.basename.split(".", 2)

    if libname.startswith("lib"):
        return libname[3:]
    else:
        return libname

def collect_deps(deps, toolchain):
    """
    Walks through dependencies and collects the transitive dependencies.

    Args:
      deps: List[Label]: The deps from ctx.attr.deps.
      name: str: Name of the current target.

    Returns:
      Returns a DepInfo provider.
    """

    # TODO: Fix depset union (https://docs.bazel.build/versions/master/skylark/depsets.html)
    direct_crates = []
    transitive_crates = depset()
    transitive_dylibs = depset(order = "topological")  # dylib link flag ordering matters.
    transitive_staticlibs = depset()
    for dep in deps:
        if CrateInfo in dep:
            # This dependency is a rust_library
            direct_crates += [dep[CrateInfo]]
            transitive_crates = depset([dep[CrateInfo]], transitive = [transitive_crates])
            transitive_crates = depset(transitive = [transitive_crates, dep[DepInfo].transitive_crates])
            transitive_dylibs = depset(transitive = [transitive_dylibs, dep[DepInfo].transitive_dylibs])
            transitive_staticlibs = depset(transitive = [transitive_staticlibs, dep[DepInfo].transitive_staticlibs])
        elif CcInfo in dep:
            # This dependency is a cc_library

            # TODO: We could let the user choose how to link, instead of always preferring to link static libraries.
            libs = get_libs_for_static_executable(dep)
            dylibs = [l for l in libs.to_list() if l.basename.endswith(toolchain.dylib_ext)]
            staticlibs = [l for l in libs.to_list() if l.basename.endswith(toolchain.staticlib_ext)]
            transitive_dylibs = depset(transitive = [transitive_dylibs, depset(dylibs)])
            transitive_staticlibs = depset(transitive = [transitive_staticlibs, depset(staticlibs)])
        else:
            fail("rust targets can only depend on rust_library, rust_*_library or cc_library targets." + str(dep), "deps")

    transitive_libs = depset(
        [c.output for c in transitive_crates.to_list()],
        transitive = [transitive_staticlibs, transitive_dylibs],
    )

    return DepInfo(
        direct_crates = depset(direct_crates),
        transitive_crates = transitive_crates,
        transitive_dylibs = transitive_dylibs,
        transitive_staticlibs = transitive_staticlibs,
        transitive_libs = transitive_libs.to_list(),
    )

def _get_linker_and_args(ctx, rpaths):
    if (len(BAZEL_VERSION) == 0 or
        versions.is_at_least("0.18.0", BAZEL_VERSION)):
        user_link_flags = ctx.fragments.cpp.linkopts
    else:
        user_link_flags = depset(ctx.fragments.cpp.linkopts)

    cc_toolchain = find_cpp_toolchain(ctx)
    kwargs = {
        "ctx": ctx,
    } if len(BAZEL_VERSION) == 0 or versions.is_at_least(
        "0.25.0", BAZEL_VERSION
    ) else {}
    feature_configuration = cc_common.configure_features(
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
        **kwargs
    )
    link_variables = cc_common.create_link_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        is_linking_dynamic_library = False,
        runtime_library_search_directories = rpaths,
        user_link_flags = user_link_flags,
    )
    link_args = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
        variables = link_variables,
    )
    link_env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
        variables = link_variables,
    )
    ld = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
    )

    return ld, link_args, link_env

def rustc_compile_action(
        ctx,
        toolchain,
        crate_info,
        output_hash = None,
        is_for_host = False,
        rust_flags = []):
    """
    Constructs the rustc command used to build the current target.

    Returns:
      List[Provider]: A list of the following providers:
                     - CrateInfo: info for the crate we just built; same as `crate_info` parameter.
                     - DepInfo: The transitive dependencies of this crate.
                     - DefaultInfo: The output file for this crate, and its runfiles.
    """
    output_dir = crate_info.output.dirname

    dep_info = collect_deps(
        crate_info.deps,
        toolchain,
    )

    linker_script = getattr(ctx.file, "linker_script") if hasattr(ctx.file, "linker_script") else None

    cc_toolchain = find_cpp_toolchain(ctx)

    if (len(BAZEL_VERSION) == 0 or
        versions.is_at_least("0.25.0", BAZEL_VERSION)):
        linker_depset = find_cpp_toolchain(ctx).all_files
    else:
        linker_depset = depset(ctx.files._cc_toolchain)

    compile_inputs = depset(
        crate_info.srcs +
        getattr(ctx.files, "data", []) +
        dep_info.transitive_libs +
        [toolchain.rustc] +
        toolchain.crosstool_files +
        ([] if linker_script == None else [linker_script]),
        transitive = [
            toolchain.rustc_lib.files,
            toolchain.rust_lib.files,
            linker_depset,
        ],
    )

    args = ctx.actions.args()
    args.add(crate_info.root)
    args.add("--crate-name=" + crate_info.name)
    args.add("--crate-type=" + crate_info.type)

    # Mangle symbols to disambiguate crates with the same name
    extra_filename = "-" + output_hash if output_hash else ""
    args.add("--codegen=metadata=" + extra_filename)
    args.add("--out-dir=" + output_dir)
    args.add("--codegen=extra-filename=" + extra_filename)

    compilation_mode = _get_compilation_mode_opts(ctx, toolchain)
    args.add("--codegen=opt-level=" + compilation_mode.opt_level)
    args.add("--codegen=debuginfo=" + compilation_mode.debug_info)

    args.add("--emit=dep-info,link")
    args.add("--color=always")
    target = toolchain.exec_triple if is_for_host else toolchain.target_triple
    args.add("--target=" + target)
    if hasattr(ctx.attr, "crate_features"):
        args.add_all(getattr(ctx.attr, "crate_features"), before_each = "--cfg", format_each = 'feature="%s"')
    if hasattr(ctx.attr, "linker_script") and linker_script != None:
        args.add(linker_script.path, format = "--codegen=link-arg=-T%s")

    # Gets the paths to the folders containing the standard library (or libcore)
    rust_lib_paths = depset([file.dirname for file in toolchain.rust_lib.files.to_list()]).to_list()
    # Tell Rustc where to find the standard library
    args.add_all(rust_lib_paths, before_each = "-L", format_each="%s")

    args.add_all(rust_flags)
    args.add_all(getattr(ctx.attr, "rustc_flags", []))
    add_edition_flags(args, crate_info)

    # Link!
    rpaths = _compute_rpaths(toolchain, output_dir, dep_info)
    ld, link_args, link_env = _get_linker_and_args(ctx, rpaths)
    args.add("--codegen=linker=" + ld)
    args.add_joined("--codegen", link_args, join_with = " ", format_joined = "link-args=%s")

    add_native_link_flags(args, dep_info)

    add_crate_link_flags(args, dep_info)

    # We awkwardly construct this command because we cannot reference $PWD from ctx.actions.run(executable=toolchain.rustc)
    out_dir = _create_out_dir_action(ctx)
    if out_dir:
        compile_inputs = depset([out_dir], transitive = [compile_inputs])
        out_dir_env = "OUT_DIR=$(pwd)/{} ".format(out_dir.path)
    else:
        out_dir_env = ""

    # Similar awkward construction to prepend execroot to the crate-root to set `CARGO_MANIFEST_DIR`
    #
    # See https://github.com/google/cargo-raze/issues/71#issuecomment-433225853 for the rationale as
    # to why
    #
    # In brief:
    #
    # Certain rust build processes expect to find files from the environment variable
    # `$CARGO_MANIFEST_DIR`. Examples of this include pest, tera, asakuma.
    #
    # The compiler and by extension proc-macros see the current working directory as the Bazel exec
    # root. Therefore, in order to fix this without an upstream code change, we have to set
    # `$CARGO_MANIFEST_DIR`.
    #
    # As such we attempt to infer `$CARGO_MANIFEST_DIR`.
    # Inference cannot be derived from `attr.crate_root`, as this points at a source file which may or
    # may not follow the `src/lib.rs` convention. As such we use `ctx.build_file_path` mapped into the
    # `exec_root`. Since we cannot (seemingly) get the `exec_root` from skylark, we cheat a little
    # and use `$(pwd)` which resolves the `exec_root` at action execution time.
    package_dir = ctx.build_file_path[:ctx.build_file_path.rfind("/")]
    manifest_dir_env = "CARGO_MANIFEST_DIR=$(pwd)/{} ".format(package_dir)
    command = '{}{}{} "$@" --remap-path-prefix="$(pwd)"=__bazel_redacted_pwd'.format(
        manifest_dir_env,
        out_dir_env,
        toolchain.rustc.path,
    )

    env = _get_rustc_env(ctx, toolchain)
    env.update(link_env)

    ctx.actions.run_shell(
        command = command,
        inputs = compile_inputs,
        outputs = [crate_info.output],
        env = env,
        arguments = [args],
        mnemonic = "Rustc",
        progress_message = "Compiling Rust {} {} ({} files)".format(crate_info.type, ctx.label.name, len(crate_info.srcs)),
    )

    runfiles = ctx.runfiles(
        files = dep_info.transitive_dylibs.to_list() + getattr(ctx.files, "data", []),
        collect_data = True,
    )

    return [
        crate_info,
        dep_info,
        DefaultInfo(
            # nb. This field is required for cc_library to depend on our output.
            files = depset([crate_info.output]),
            runfiles = runfiles,
        ),
    ]

def add_edition_flags(args, crate):
    if crate.edition != "2015":
        args.add("--edition={}".format(crate.edition))

def _create_out_dir_action(ctx):
    tar_file = getattr(ctx.file, "out_dir_tar", None)
    if not tar_file:
        return None

    out_dir = ctx.actions.declare_directory(ctx.label.name + ".out_dir")
    ctx.actions.run_shell(
        # TODO: Remove system tar usage
        command = "rm -fr {dir} && mkdir {dir} && tar -xzf {tar} -C {dir}".format(tar = tar_file.path, dir = out_dir.path),
        inputs = [tar_file],
        outputs = [out_dir],
        use_default_shell_env = True,  # Sets PATH for tar and gzip (tar's dependency)
    )
    return out_dir

def _compute_rpaths(toolchain, output_dir, dep_info):
    """
    Determine the artifact's rpaths relative to the bazel root
    for runtime linking of shared libraries.
    """
    if not dep_info.transitive_dylibs:
        return depset([])
    if toolchain.os != "linux":
        fail("Runtime linking is not supported on {}, but found {}".format(
            toolchain.os,
            dep_info.transitive_dylibs,
        ))

    # Multiple dylibs can be present in the same directory, so deduplicate them.
    return depset([
        relative_path(output_dir, lib_dir)
        for lib_dir in _get_dir_names(dep_info.transitive_dylibs.to_list())
    ])

def _get_dir_names(files):
    dirs = {}
    for f in files:
        dirs[f.dirname] = None
    return dirs.keys()

def add_crate_link_flags(args, dep_info):
    # nb. Crates are linked via --extern regardless of their crate_type
    args.add_all(dep_info.direct_crates, map_each = _crate_to_link_flag)
    args.add_all(
        dep_info.transitive_crates,
        map_each = _get_crate_dirname,
        uniquify = True,
        format_each = "-Ldependency=%s",
    )

def _crate_to_link_flag(crate_info):
    return ["--extern", "{}={}".format(crate_info.name, crate_info.output.path)]

def _get_crate_dirname(crate):
    return crate.output.dirname

def add_native_link_flags(args, dep_info):
    native_libs = depset(transitive = [dep_info.transitive_dylibs, dep_info.transitive_staticlibs])
    args.add_all(native_libs, map_each = _get_dirname, uniquify = True, format_each = "-Lnative=%s")
    args.add_all(dep_info.transitive_dylibs, map_each = get_lib_name, format_each = "-ldylib=%s")
    args.add_all(dep_info.transitive_staticlibs, map_each = get_lib_name, format_each = "-lstatic=%s")

def _get_dirname(file):
    return file.dirname
