import Testing
@testable import CupThreadFeedback

// Regression tests for issue #594: `registrableDomain(of:)` must match the
// longest listed suffix, so sibling tenants of a multi-label hosted service
// (S3 buckets, R2 buckets) are never treated as the same site by
// `isAllowedDownloadHost`.

@Suite("DownloadHostMultiLabelSuffix")
struct DownloadHostMultiLabelSuffixTests {
    @Test("Sibling buckets on a regional S3 endpoint are different sites")
    func regionalS3SiblingsRefused() {
        #expect(isAllowedDownloadHost(
            "attacker.s3.us-east-1.amazonaws.com",
            baseHost: "mybucket.s3.us-east-1.amazonaws.com"
        ) == false)
        #expect(isAllowedDownloadHost(
            "mybucket.s3.us-west-2.amazonaws.com",
            baseHost: "mybucket.s3.us-east-1.amazonaws.com"
        ) == false)
    }

    @Test("Sibling buckets on the global S3 endpoint are different sites")
    func globalS3SiblingsRefused() {
        #expect(isAllowedDownloadHost(
            "attackerbucket.s3.amazonaws.com",
            baseHost: "mybucket.s3.amazonaws.com"
        ) == false)
    }

    @Test("Dualstack and FIPS S3 endpoints keep tenants separate")
    func dualstackAndFIPSS3Refused() {
        #expect(isAllowedDownloadHost(
            "attacker.s3.dualstack.us-east-1.amazonaws.com",
            baseHost: "mybucket.s3.dualstack.us-east-1.amazonaws.com"
        ) == false)
        #expect(isAllowedDownloadHost(
            "attacker.s3-fips.us-gov-west-1.amazonaws.com",
            baseHost: "mybucket.s3-fips.us-gov-west-1.amazonaws.com"
        ) == false)
    }

    @Test("R2 buckets are their own sites")
    func r2BucketIsolation() {
        #expect(isAllowedDownloadHost(
            "attacker.r2.cloudflarestorage.com",
            baseHost: "mybucket.r2.cloudflarestorage.com"
        ) == false)
        #expect(isAllowedDownloadHost(
            "mybucket.r2.cloudflarestorage.com",
            baseHost: "mybucket.r2.cloudflarestorage.com"
        ))
    }

    @Test("Bare service suffixes fail closed like other public suffixes")
    func bareServiceSuffixFailsClosed() {
        #expect(isAllowedDownloadHost("api.cupthread.com", baseHost: "s3.us-east-1.amazonaws.com") == false)
        #expect(isAllowedDownloadHost("s3.amazonaws.com", baseHost: "mybucket.s3.amazonaws.com") == false)
        #expect(isAllowedDownloadHost("r2.cloudflarestorage.com", baseHost: "mybucket.r2.cloudflarestorage.com") == false)
    }

    @Test("Service tenants never match an unrelated base host")
    func serviceTenantAgainstUnrelatedBase() {
        #expect(isAllowedDownloadHost("evil.s3.us-east-1.amazonaws.com", baseHost: "api.cupthread.com") == false)
        #expect(isAllowedDownloadHost("evil.r2.cloudflarestorage.com", baseHost: "api.cupthread.com") == false)
    }

    @Test("Two-label suffix and ccSLD behavior is unchanged")
    func twoLabelBehaviorUnchanged() {
        #expect(isAllowedDownloadHost("a.github.io", baseHost: "b.github.io") == false)
        #expect(isAllowedDownloadHost("x.co.uk", baseHost: "y.co.uk") == false)
        #expect(isAllowedDownloadHost("site.co.uk", baseHost: "site.co.uk"))
        #expect(isAllowedDownloadHost("cdn.cupthread.com", baseHost: "api.cupthread.com"))
        #expect(isAllowedDownloadHost("cupthread.com", baseHost: "api.cupthread.com"))
        #expect(isAllowedDownloadHost("MYBUCKET.S3.AMAZONAWS.COM", baseHost: "mybucket.s3.amazonaws.com."))
    }

    @Test("Unlisted hosting suffixes remain a documented curated-list limitation")
    func unlistedHostingSuffixPinnedBehavior() {
        // Not in the curated suffix set, so tenants collapse onto the apex and
        // sibling tenants are (incorrectly) accepted. This pins the known
        // limitation recorded in the `multiTenantHostSuffixes` doc comment
        // (issue #594) — expanding the list flips both expectations.
        #expect(isAllowedDownloadHost("attacker.amplifyapp.com", baseHost: "myapp.amplifyapp.com"))
        #expect(isAllowedDownloadHost(
            "other.container.blob.core.windows.net",
            baseHost: "my.container.blob.core.windows.net"
        ))
    }
}
