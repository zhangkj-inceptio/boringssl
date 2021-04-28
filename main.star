#!/usr/bin/env lucicfg

"""
lucicfg definitions for BoringSSL's CI and CQ.
"""

lucicfg.check_version("1.23.0")

# Enable LUCI Realms support.
lucicfg.enable_experiment("crbug.com/1085650")
# Launch all builds in "realms-aware mode", crbug.com/1203847.
luci.builder.defaults.experiments.set({"luci.use_realms": 100})

lucicfg.config(
    lint_checks = ["default"],
)

REPO_URL = "https://boringssl.googlesource.com/boringssl"
RECIPE_BUNDLE = "infra/recipe_bundles/chromium.googlesource.com/chromium/tools/build"

luci.project(
    name = "boringssl",
    buildbucket = "cr-buildbucket.appspot.com",
    logdog = "luci-logdog.appspot.com",
    milo = "luci-milo.appspot.com",
    notify = "luci-notify.appspot.com",
    scheduler = "luci-scheduler.appspot.com",
    swarming = "chromium-swarm.appspot.com",
    acls = [
        acl.entry(
            roles = [
                acl.BUILDBUCKET_READER,
                acl.LOGDOG_READER,
                acl.PROJECT_CONFIGS_READER,
                acl.SCHEDULER_READER,
            ],
            groups = "all",
        ),
        acl.entry(
            roles = acl.CQ_COMMITTER,
            groups = "project-boringssl-committers",
        ),
        acl.entry(
            roles = acl.CQ_DRY_RUNNER,
            groups = "project-boringssl-tryjob-access",
        ),
        acl.entry(
            roles = acl.SCHEDULER_OWNER,
            groups = "project-boringssl-admins",
        ),
        acl.entry(
            roles = acl.LOGDOG_WRITER,
            groups = "luci-logdog-chromium-writers",
        ),
    ],
)

luci.bucket( name = "ci",)

luci.bucket(
    name = "try",
    acls = [
        # Allow launching tryjobs directly (in addition to doing it through CQ).
        acl.entry(
            roles = acl.BUILDBUCKET_TRIGGERER,
            groups = [
                "project-boringssl-tryjob-access",
                "service-account-cq",
            ],
        ),
    ],
)

luci.milo(
    logo = "https://storage.googleapis.com/chrome-infra/boringssl-logo.png",
)

console_view = luci.console_view(
    name = "main",
    repo = REPO_URL,
    title = "BoringSSL Main Console",
)

luci.cq(
    submit_max_burst = 4,
    submit_burst_delay = 480 * time.second,
    # TODO(davidben): Can this be removed? It is marked as optional and
    # deprecated. It was included as part of porting over from commit-queue.cfg.
    status_host = "chromium-cq-status.appspot.com",
)

cq_group = luci.cq_group(
    name = "Main CQ",
    watch = cq.refset(REPO_URL, refs = ["refs/heads/.+"]),
    retry_config = cq.RETRY_ALL_FAILURES,
)

poller = luci.gitiles_poller(
    name = "master-gitiles-trigger",
    bucket = "ci",
    repo = REPO_URL,
)

luci.logdog(
    gs_bucket = "chromium-luci-logdog",
)

notifier = luci.notifier(
    name = "all",
    on_occurrence = ["FAILURE", "INFRA_FAILURE"],
    on_new_status = ["SUCCESS"],
    notify_emails = ["boringssl@google.com"],
)

DEFAULT_TIMEOUT = 30 * time.minute

def ci_builder(
        name,
        host,
        *,
        recipe = "boringssl",
        category = None,
        short_name = None,
        properties = {}):
    dimensions = dict(host["dimensions"])
    dimensions["pool"] = "luci.flex.ci"
    caches = [swarming.cache("gocache"), swarming.cache("gopath")]
    if "caches" in host:
        caches += host["caches"]
    properties = dict(properties)
    properties["$gatekeeper"] = {"group": "client.boringssl"}
    builder = luci.builder(
        name = name,
        bucket = "ci",
        executable = luci.recipe(
            name = recipe,
            cipd_package = RECIPE_BUNDLE,
        ),
        service_account = "boringssl-ci-builder@chops-service-accounts.iam.gserviceaccount.com",
        dimensions = dimensions,
        execution_timeout = host.get("execution_timeout", DEFAULT_TIMEOUT),
        caches = caches,
        notifies = [notifier],
        triggered_by = [poller],
        properties = properties,
    )
    luci.console_view_entry(
        builder = builder,
        console_view = console_view,
        category = category,
        short_name = short_name,
    )

def cq_builder(name, host, *, recipe = "boringssl", cq_enabled = True, properties = {}):
    dimensions = dict(host["dimensions"])
    dimensions["pool"] = "luci.flex.try"
    builder = luci.builder(
        name = name,
        bucket = "try",
        executable = luci.recipe(
            name = recipe,
            cipd_package = RECIPE_BUNDLE,
        ),
        service_account = "boringssl-try-builder@chops-service-accounts.iam.gserviceaccount.com",
        dimensions = dimensions,
        execution_timeout = host.get("execution_timeout", DEFAULT_TIMEOUT),
        caches = host.get("caches"),
        properties = properties,
    )
    luci.cq_tryjob_verifier(
        builder = builder,
        cq_group = cq_group,
        includable_only = not cq_enabled,
    )

def both_builders(
        name,
        host,
        *,
        recipe = "boringssl",
        category = None,
        short_name = None,
        cq_enabled = True,
        cq_compile_only = False,
        cq_host = None,
        properties = {}):
    ci_builder(
        name,
        host,
        recipe = recipe,
        category = category,
        short_name = short_name,
        properties = properties,
    )
    cq_name = name
    cq_properties = dict(properties)
    if cq_compile_only:
        cq_name += "_compile"
        cq_properties["run_unit_tests"] = False
        cq_properties["run_ssl_tests"] = False
    if cq_host == None:
        cq_host = host
    cq_builder(
        cq_name,
        cq_host,
        recipe = recipe,
        cq_enabled = cq_enabled,
        properties = cq_properties,
    )

LINUX_HOST = {
    "dimensions": {
        "os": "Ubuntu-16.04",
        "cpu": "x86-64",
    },
}

MAC_HOST = {
    "dimensions": {
        "os": "Mac-10.15",
        "cpu": "x86-64",
    },
    "caches": [swarming.cache("osx_sdk")],
    # xcode installation can take a while, particularly when running
    # concurrently on multiple VMs on the same host. See crbug.com/1063870
    # for more context.
    "execution_timeout": 60 * time.minute,
}

WIN_HOST = {
    "dimensions": {
        "os": "Windows-10",
        "cpu": "x86-64",
    },
    "caches": [swarming.cache("win_toolchain")],
}

# The Android tests take longer to run. See https://crbug.com/900953.
ANDROID_TIMEOUT = 60 * time.minute

BULLHEAD_HOST = {
    "dimensions": {
        "device_type": "bullhead",  # Nexus 5X
    },
    "execution_timeout": ANDROID_TIMEOUT,
}

WALLEYE_HOST = {
    "dimensions": {
        "device_type": "walleye",  # Pixel 2
    },
    "execution_timeout": ANDROID_TIMEOUT,
}

# TODO(davidben): Switch the BoringSSL recipe to specify most flags in
# properties rather than parsing names. Then we can add new configurations
# without having to touch multiple repositories.

both_builders(
    "android_aarch64",
    BULLHEAD_HOST,
    category = "android|aarch64",
    short_name = "dbg",
    cq_host = LINUX_HOST,
    cq_compile_only = True,
)
both_builders(
    "android_aarch64_rel",
    BULLHEAD_HOST,
    category = "android|aarch64",
    short_name = "rel",
    cq_host = LINUX_HOST,
    cq_compile_only = True,
    cq_enabled = False,
)
both_builders(
    "android_aarch64_fips",
    # The Android FIPS configuration requires a newer device.
    WALLEYE_HOST,
    category = "android|aarch64",
    short_name = "fips",
    cq_host = LINUX_HOST,
    cq_compile_only = True,
)
both_builders(
    "android_arm",
    BULLHEAD_HOST,
    category = "android|thumb",
    short_name = "dbg",
    cq_host = LINUX_HOST,
    cq_compile_only = True,
)
both_builders(
    "android_arm_rel",
    BULLHEAD_HOST,
    category = "android|thumb",
    short_name = "rel",
    cq_host = LINUX_HOST,
    cq_compile_only = True,
    cq_enabled = False,
)
both_builders(
    "android_arm_armmode_rel",
    BULLHEAD_HOST,
    category = "android|arm",
    short_name = "rel",
    cq_host = LINUX_HOST,
    cq_compile_only = True,
    cq_enabled = False,
)

# TODO(davidben): It's strange that the CI runs ARM mode in release mode while
# the CQ compiles ARM mode in debug. Align these?
cq_builder(
    "android_arm_armmode_compile",
    LINUX_HOST,
    properties = {
        "run_unit_tests": False,
        "run_ssl_tests": False,
    },
)

both_builders("docs", LINUX_HOST, recipe = "boringssl_docs", short_name = "doc")
both_builders(
    "ios_compile",
    MAC_HOST,
    category = "ios",
    short_name = "32",
    properties = {
        "run_unit_tests": False,
        "run_ssl_tests": False,
    },
)
both_builders(
    "ios64_compile",
    MAC_HOST,
    category = "ios",
    short_name = "64",
    properties = {
        "run_unit_tests": False,
        "run_ssl_tests": False,
    },
)
both_builders("linux", LINUX_HOST, category = "linux", short_name = "dbg")
both_builders("linux_rel", LINUX_HOST, category = "linux", short_name = "rel")
both_builders("linux32", LINUX_HOST, category = "linux|32", short_name = "dbg")
both_builders("linux32_rel", LINUX_HOST, category = "linux|32", short_name = "rel")
ci_builder("linux32_sde", LINUX_HOST, category = "linux|32", short_name = "sde")
both_builders(
    "linux32_nosse2_noasm",
    LINUX_HOST,
    category = "linux|32",
    short_name = "nosse2",
)
both_builders(
    "linux_clang_cfi",
    LINUX_HOST,
    category = "linux|clang",
    short_name = "cfi",
    cq_enabled = False,
)
both_builders(
    "linux_clang_rel",
    LINUX_HOST,
    category = "linux|clang",
    short_name = "rel",
)
both_builders(
    "linux_clang_rel_msan",
    LINUX_HOST,
    category = "linux|clang",
    short_name = "msan",
)
both_builders(
    "linux_clang_rel_tsan",
    LINUX_HOST,
    category = "linux|clang",
    short_name = "tsan",
    cq_enabled = False,
)
both_builders("linux_fips", LINUX_HOST, category = "linux|fips", short_name = "dbg")
both_builders(
    "linux_fips_rel",
    LINUX_HOST,
    category = "linux|fips",
    short_name = "rel",
)
both_builders(
    "linux_fips_clang",
    LINUX_HOST,
    category = "linux|fips|clang",
    short_name = "dbg",
)
both_builders(
    "linux_fips_clang_rel",
    LINUX_HOST,
    category = "linux|fips|clang",
    short_name = "rel",
)
both_builders(
    "linux_fips_noasm_asan",
    LINUX_HOST,
    category = "linux|fips",
    short_name = "asan",
)
both_builders("linux_fuzz", LINUX_HOST, category = "linux", short_name = "fuzz")
both_builders(
    "linux_noasm_asan",
    LINUX_HOST,
    category = "linux",
    short_name = "asan",
)
both_builders(
    "linux_nothreads",
    LINUX_HOST,
    category = "linux",
    short_name = "not",
)
ci_builder("linux_sde", LINUX_HOST, category = "linux", short_name = "sde")
both_builders("linux_shared", LINUX_HOST, category = "linux", short_name = "sh")
both_builders("linux_small", LINUX_HOST, category = "linux", short_name = "sm")
both_builders(
    "linux_nosse2_noasm",
    LINUX_HOST,
    category = "linux",
    short_name = "nosse2",
)
both_builders("mac", MAC_HOST, category = "mac", short_name = "dbg")
both_builders("mac_rel", MAC_HOST, category = "mac", short_name = "rel")
both_builders("mac_small", MAC_HOST, category = "mac", short_name = "sm")
both_builders("win32", WIN_HOST, category = "win|32", short_name = "dbg")
both_builders("win32_rel", WIN_HOST, category = "win|32", short_name = "rel")
ci_builder("win32_sde", WIN_HOST, category = "win|32", short_name = "sde")
both_builders("win32_small", WIN_HOST, category = "win|32", short_name = "sm")

# To reduce cycle times, the CQ VS2017 builders are compile-only.
both_builders(
    "win32_vs2017",
    WIN_HOST,
    category = "win|32|vs 2017",
    short_name = "dbg",
    cq_compile_only = True,
    properties = {
        "gclient_vars": {"vs_version": "2017"},
    },
)
both_builders(
    "win32_vs2017_clang",
    WIN_HOST,
    category = "win|32|vs 2017",
    short_name = "clg",
    cq_compile_only = True,
    properties = {
        "gclient_vars": {"vs_version": "2017"},
    },
)

both_builders("win64", WIN_HOST, category = "win|64", short_name = "dbg")
both_builders("win64_rel", WIN_HOST, category = "win|64", short_name = "rel")
ci_builder("win64_sde", WIN_HOST, category = "win|64", short_name = "sde")
both_builders("win64_small", WIN_HOST, category = "win|64", short_name = "sm")

# To reduce cycle times, the CQ VS2017 builders are compile-only.
both_builders(
    "win64_vs2017",
    WIN_HOST,
    category = "win|64|vs 2017",
    short_name = "dbg",
    cq_compile_only = True,
    properties = {
        "gclient_vars": {"vs_version": "2017"},
    },
)
both_builders(
    "win64_vs2017_clang",
    WIN_HOST,
    category = "win|64|vs 2017",
    short_name = "clg",
    cq_compile_only = True,
    properties = {
        "gclient_vars": {"vs_version": "2017"},
    },
)

both_builders(
    "win_arm64_compile",
    WIN_HOST,
    category = "win",
    short_name = "arm64",
    cq_enabled = False,
    properties = {
        "clang": True,
        "cmake_args": {
            "CMAKE_SYSTEM_NAME": "Windows",
            "CMAKE_SYSTEM_PROCESSOR": "arm64",
            "CMAKE_ASM_FLAGS": "--target=arm64-windows",
            "CMAKE_CXX_FLAGS": "--target=arm64-windows",
            "CMAKE_C_FLAGS": "--target=arm64-windows",
        },
        "gclient_vars": {
            "checkout_nasm": False,
            "vs_version": "2017",
        },
        "msvc_target": "arm64",
        "run_unit_tests": False,
        "run_ssl_tests": False,
    },
)
