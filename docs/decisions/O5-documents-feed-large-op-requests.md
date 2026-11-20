---
id: O5
date: 2026-11-20
area: Releases
---

# The documents feed's `limit` sizes only its first request of an op

**Decision.** `GET /v1/documents/changes` still returns whole ops, and a page still holds its
first op and at most `limit - 1` changes past it. But once the first op is known to continue past
the first request (sized by the caller's `limit`), the rest of it is read in requests of the
largest size one `get_changes` returns. What those requests read past the op's last change is not
returned: the page is cut at the first change of another op, its `cursor` is that change's
timestamp, and `more` is true even if the request reached the feed's end. The loop is bounded by
`2 + ceil(changes_per_op_max / changes_request_max)` requests.

**Reason.** Reading on in requests of `limit` made one HTTP read cost about (changes in the op ÷
`limit`) sequential cluster round trips: about 8 s for `limit=1` on an idle machine, and past the
30 s request timeout on a loaded one (NRV-E0606, NervaOrg/nerva#1). `limit` bounds what a page
returns, not how the server reads; the reply's shape and its page sizes are as before.

**Cost.** A page read with a small `limit` may scan more changes per request than `limit` and
discard those past the op, so the server allocates a request of the largest size (per HTTP request,
from its arena), and the next page rereads what was discarded. Only a page that continues an op
past its first request pays this.
