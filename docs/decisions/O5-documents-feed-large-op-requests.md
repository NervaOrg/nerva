---
id: O5
date: 2026-11-20
area: Releases
---

# The documents feed's `limit` sizes only its first request of an op

**Decision.** `GET /v1/documents/changes` still returns whole ops, but once an op is known to
continue past the first request (sized by the caller's `limit`), the rest of it is read in requests
of the largest size one `get_changes` returns. The loop is bounded by
`2 + ceil(changes_per_op_max / changes_request_max)` requests.

**Reason.** Reading on in requests of `limit` made one HTTP read cost about (changes in the op ÷
`limit`) sequential cluster round trips: about 8 s for `limit=1` on an idle machine, and past the
30 s request timeout on a loaded one (NRV-E0606, NervaOrg/nerva#1). `limit` bounds what a page
returns, not how the server reads; the reply is unchanged.

**Cost.** A page read with a small `limit` may now scan more changes per request than `limit`,
so the server allocates a page of the largest request size (per HTTP request, from its arena).
