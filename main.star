#!/usr/bin/env lucicfg

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

luci.bucket(
    name = "ci",
    acls = [
        acl.entry(
            roles = acl.BUILDBUCKET_TRIGGERER,
            users = "luci-scheduler@appspot.gserviceaccount.com",
        ),
        acl.entry(
            roles = acl.BUILDBUCKET_OWNER,
            users = "luci-migration@appspot.gserviceaccount.com",
        ),
    ],
)

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
    logo = "https://storage.googleapis.com/chrome-infra/boringssl-logo.png"
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

def ci_builder(name, host, *, recipe="boringssl", category=None,
               short_name=None):
    dimensions = dict(host["dimensions"])
    dimensions["pool"] = "luci.flex.ci"
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
        caches = host.get("caches"),
        notifies = [notifier],
        triggered_by = [poller],
        properties = {
            "$gatekeeper": { "group": "client.boringssl" },
        },
    )
    luci.console_view_entry(
        builder = builder,
        console_view = console_view,
        category = category,
        short_name = short_name,
    )

def cq_builder(name, host, *, recipe="boringssl", enabled=True):
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
    )
    luci.cq_tryjob_verifier(
        builder = builder,
        cq_group = cq_group,
        includable_only = not enabled,
    )

LINUX_HOST = {
    "dimensions": {
        "os": "Ubuntu-16.04",
        "cpu": "x86-64",
    },
}

MAC_HOST = {
    "dimensions": {
        "os": "Mac-10.13",
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

WIN7_HOST = {
    "dimensions": {
        "os": "Windows-7-SP1",
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

ci_builder("android_aarch64", BULLHEAD_HOST, category="android|aarch64",
           short_name="dbg")
ci_builder("android_aarch64_rel", BULLHEAD_HOST, category="android|aarch64",
           short_name="rel")
# The Android FIPS configuration requires a newer device.
ci_builder("android_aarch64_fips", WALLEYE_HOST, category="android|aarch64",
           short_name="fips")
ci_builder("android_arm", BULLHEAD_HOST, category="android|thumb",
           short_name="dbg")
ci_builder("android_arm_rel", BULLHEAD_HOST, category="android|thumb",
           short_name="rel")
ci_builder("android_arm_armmode_rel", BULLHEAD_HOST, category="android|arm",
           short_name="rel")
ci_builder("docs", LINUX_HOST, recipe="boringssl_docs", short_name="doc")
ci_builder("ios_compile", MAC_HOST, category="ios", short_name="32")
ci_builder("ios64_compile", MAC_HOST, category="ios", short_name="64")
ci_builder("linux", LINUX_HOST, category="linux", short_name="dbg")
ci_builder("linux_rel", LINUX_HOST, category="linux", short_name="rel")
ci_builder("linux32", LINUX_HOST, category="linux|32", short_name="dbg")
ci_builder("linux32_rel", LINUX_HOST, category="linux|32", short_name="rel")
ci_builder("linux32_sde", LINUX_HOST, category="linux|32", short_name="sde")
ci_builder("linux32_nosse2_noasm", LINUX_HOST, category="linux|32",
           short_name="nosse2")
ci_builder("linux_clang_cfi", LINUX_HOST, category="linux|clang",
           short_name="cfi")
ci_builder("linux_clang_rel", LINUX_HOST, category="linux|clang",
           short_name="rel")
ci_builder("linux_clang_rel_msan", LINUX_HOST, category="linux|clang",
           short_name="msan")
ci_builder("linux_clang_rel_tsan", LINUX_HOST, category="linux|clang",
           short_name="tsan")
ci_builder("linux_fips", LINUX_HOST, category="linux|fips", short_name="dbg")
ci_builder("linux_fips_rel", LINUX_HOST, category="linux|fips",
           short_name="rel")
ci_builder("linux_fips_clang", LINUX_HOST, category="linux|fips|clang",
           short_name="dbg")
ci_builder("linux_fips_clang_rel", LINUX_HOST, category="linux|fips|clang",
           short_name="rel")
ci_builder("linux_fips_noasm_asan", LINUX_HOST, category="linux|fips",
           short_name="asan")
ci_builder("linux_fuzz", LINUX_HOST, category="linux", short_name="fuzz")
ci_builder("linux_noasm_asan", LINUX_HOST, category="linux",
           short_name="asan")
ci_builder("linux_nothreads", LINUX_HOST, category="linux",
           short_name="not")
ci_builder("linux_sde", LINUX_HOST, category="linux", short_name="sde")
ci_builder("linux_shared", LINUX_HOST, category="linux", short_name="sh")
ci_builder("linux_small", LINUX_HOST, category="linux", short_name="sm")
ci_builder("linux_nosse2_noasm", LINUX_HOST, category="linux",
           short_name="nosse2")
ci_builder("mac", MAC_HOST, category="mac", short_name="dbg")
ci_builder("mac_rel", MAC_HOST, category="mac", short_name="rel")
ci_builder("mac_small", MAC_HOST, category="mac", short_name="sm")
ci_builder("win32", WIN_HOST, category="win|32", short_name="dbg")
ci_builder("win32_nasm", WIN_HOST, category="win|32", short_name="nasm")
ci_builder("win32_rel", WIN_HOST, category="win|32", short_name="rel")
ci_builder("win32_sde", WIN_HOST, category="win|32", short_name="sde")
ci_builder("win32_small", WIN_HOST, category="win|32", short_name="sm")
ci_builder("win32_vs2017", WIN_HOST, category="win|32|vs 2017",
           short_name="dbg")
ci_builder("win32_vs2017_clang", WIN_HOST, category="win|32|vs 2017",
           short_name="clg")
ci_builder("win64", WIN_HOST, category="win|64", short_name="dbg")
ci_builder("win64_nasm", WIN_HOST, category="win|64", short_name="nasm")
ci_builder("win64_rel", WIN_HOST, category="win|64", short_name="rel")
ci_builder("win64_sde", WIN_HOST, category="win|64", short_name="sde")
ci_builder("win64_small", WIN_HOST, category="win|64", short_name="sm")
ci_builder("win64_vs2017", WIN_HOST, category="win|64|vs 2017",
           short_name="dbg")
ci_builder("win64_vs2017_clang", WIN_HOST, category="win|64|vs 2017",
           short_name="clg")

# TODO(davidben): The CQ definitions are largely redundant with the CI
# definitions. Most divergences are unintentional. They are defined separately
# for now so the migration to lucicfg can preserve the old behavior. Next the
# definitions should be merged together.
cq_builder("android_aarch64_compile", LINUX_HOST)
cq_builder("android_aarch64_fips_compile", LINUX_HOST)
cq_builder("android_aarch64_rel_compile", LINUX_HOST, enabled=False)
cq_builder("android_arm_armmode_compile", LINUX_HOST)
cq_builder("android_arm_armmode_rel_compile", LINUX_HOST, enabled=False)
cq_builder("android_arm_compile", LINUX_HOST)
cq_builder("android_arm_rel_compile", LINUX_HOST, enabled=False)
cq_builder("docs", LINUX_HOST, recipe="boringssl_docs")
cq_builder("ios64_compile", MAC_HOST)
cq_builder("ios_compile", MAC_HOST)
cq_builder("linux", LINUX_HOST)
cq_builder("linux32", LINUX_HOST)
cq_builder("linux32_nosse2_noasm", LINUX_HOST)
cq_builder("linux32_rel", LINUX_HOST)
cq_builder("linux_clang_cfi", LINUX_HOST, enabled=False)
cq_builder("linux_clang_rel", LINUX_HOST)
cq_builder("linux_clang_rel_msan", LINUX_HOST)
cq_builder("linux_clang_rel_tsan", LINUX_HOST, enabled=False)
cq_builder("linux_fips", LINUX_HOST)
cq_builder("linux_fips_clang", LINUX_HOST)
cq_builder("linux_fips_clang_rel", LINUX_HOST)
cq_builder("linux_fips_noasm_asan", LINUX_HOST)
cq_builder("linux_fips_rel", LINUX_HOST)
cq_builder("linux_fuzz", LINUX_HOST)
cq_builder("linux_noasm_asan", LINUX_HOST)
cq_builder("linux_nosse2_noasm", LINUX_HOST)
cq_builder("linux_nothreads", LINUX_HOST)
cq_builder("linux_rel", LINUX_HOST)
cq_builder("linux_shared", LINUX_HOST)
cq_builder("linux_small", LINUX_HOST)
cq_builder("mac", MAC_HOST)
cq_builder("mac_rel", MAC_HOST)
cq_builder("mac_small", MAC_HOST)
# Historically, the VS2015 builders used Windows 7. The VS2017 builders use
# Windows 10 because there is more capacity available, and they are not affected
# by the E:\b\depot_tools issue of https://crbug.com/852609.
#
# TODO(davidben): There is more Windows 10 capacity, so switch the VS2015
# builders to Windows 10 when unifying the CI and CQ configuration. We can then
# add Windows 7 coverage to the CI rather than CQ if we need it.
cq_builder("win32", WIN7_HOST)
cq_builder("win32_clang_vs2017_compile", WIN_HOST)
cq_builder("win32_rel", WIN7_HOST)
cq_builder("win32_small", WIN7_HOST)
cq_builder("win32_vs2017_compile", WIN_HOST)
cq_builder("win64", WIN7_HOST)
cq_builder("win64_clang_vs2017_compile", WIN_HOST)
cq_builder("win64_rel", WIN7_HOST)
cq_builder("win64_small", WIN7_HOST)
cq_builder("win64_vs2017_compile", WIN_HOST)
