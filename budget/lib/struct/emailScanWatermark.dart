// Pure helpers for the email-scan timestamp watermark. No I/O — unit-tested.

// Fresh installs backfill emails received within this window before "now".
const Duration emailScanBackfillWindow = Duration(days: 30);

// Gmail list page size.
const int emailScanPageSize = 100;

// Safety cap on how many id-only list pages we page through (ids are cheap).
const int emailScanMaxListPages = 100;

// Cap on the expensive get()+process work per scan (oldest-first).
const int emailScanMaxProcessPerScan = 500;

// Gmail's search query is second-granular; build "after:<unix seconds>".
String buildGmailAfterQuery(int watermarkMs) {
  return 'after:${watermarkMs ~/ 1000}';
}

// An email is unprocessed iff strictly newer than the watermark. Equality means
// it sat at the exact boundary second the (second-granular) after: query can
// re-return, and was already handled last scan.
bool isNewerThanWatermark(int internalDateMs, int watermarkMs) {
  return internalDateMs > watermarkMs;
}

// New watermark = newest handled email, never moving backward.
int advanceWatermark(int currentMs, Iterable<int> handledInternalDatesMs) {
  int result = currentMs;
  for (final ms in handledInternalDatesMs) {
    if (ms > result) result = ms;
  }
  return result;
}

// First-run watermark: fresh install backfills 30 days; an install that already
// has email-scanned transactions starts at now (forward-only) so a backfill
// cannot re-create them.
int initialWatermarkMs(int nowMs, bool hasExistingEmailTransactions) {
  return hasExistingEmailTransactions
      ? nowMs
      : nowMs - emailScanBackfillWindow.inMilliseconds;
}
