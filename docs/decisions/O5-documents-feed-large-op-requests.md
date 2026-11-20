---
id: O5
date: 2026-11-20
area: "Milestone 3: positioned reads and the first views"
---

# The documents feed reads a large op in large requests, and its pages do not change

**Decision.** `GET /v1/documents/changes` returns exactly the pages it returned before: for the
same cursor and `limit`, the same documents, `cursor`, `more` and `op`. Only the number of cluster
requests a page takes changes. A page was read in windows of `limit` changes (at most one
request's worth); it ended at the last window that held a change of a second op, keeping every
whole op in it but the trailing one. Once the first op's length `n` is known (a change of another
op, or the feed's end, has been read), that last window ends `limit * (n / limit + 1)` changes
from the page's start. So after the first request (sized by `limit`) shows that the first op
continues, the rest of the op is read in the largest requests one `get_changes` returns, and one
more request of fewer than `limit` changes reads up to that window's end if the large requests
stopped short of it. Whatever was read past the window's end is discarded. The loop is bounded by
`2 + ceil(changes_per_op_max / changes_request_max)` requests.

**Reason.** Reading on in requests of `limit` made one HTTP read cost about (changes in the op ÷
`limit`) sequential cluster round trips: about 8 s for `limit=1` on an idle machine, and past the
30 s request timeout on a loaded one (NRV-E0606, NervaOrg/nerva#1). `limit` bounds what a page
returns, not how the server reads, so no client sees a different page.

**Cost.** A page read with a small `limit` may scan more changes per request than `limit` and
discard those past its last window, so the server allocates a request of the largest size (per
HTTP request, from its arena), and the next page rereads what was discarded. Only a page that
continues an op past its first request pays this. A differential unit test runs the previous loop as a reference model against random feeds and limits and checks the pages
are identical.
