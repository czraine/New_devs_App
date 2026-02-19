# Revenue Dashboard Bug Report

## Scope
This file documents confirmed or highly likely bugs tied to the reported revenue accuracy, cross-tenant privacy, and cents-off discrepancies.

## Bugs

## Client A (Sunset Properties)

### A1) Precision loss from Decimal-to-float conversion
**Symptom:** Revenue totals are off by a few cents (finance team report).

**Root cause:** Backend converts decimal strings to float, which introduces floating-point rounding errors, and the UI rounds again.

- `float(revenue_data['total'])` in API response
- File: [backend/app/api/v1/dashboard.py](backend/app/api/v1/dashboard.py#L16-L24)

**Secondary rounding:** Frontend rounds again with `Math.round(total * 100) / 100`.
- File: [frontend/src/components/RevenueSummary.tsx](frontend/src/components/RevenueSummary.tsx#L64-L64)

**Impact:** Small but visible cents-off discrepancies in monthly/total revenue.

**How to trigger (reliable):**
- In Swagger, call `/api/v1/auth/login` with Sunset credentials.
- Copy the token, then call `/api/v1/dashboard/summary?property_id=prop-002` with `Authorization: Bearer <token>`.
- Compare the `total_revenue` value to the UI display for the same property; note rounding differences.

**Simple fix:** Keep amounts as decimal strings in API responses and format on the UI without converting to float.

---

### A2) Monthly totals not using real DB aggregation
**Symptom:** Client A’s “March totals” do not match internal records.

**Root cause:** The monthly revenue function is a placeholder and always returns `0`, so any monthly view that depends on it will be incorrect.

- File: [backend/app/services/reservations.py](backend/app/services/reservations.py#L5-L32)

**Impact:** Monthly totals (including March) can be wrong or empty.

**How to trigger (reliable):**
- In Swagger, search for any endpoint calling monthly revenue or run a local test that invokes `calculate_monthly_revenue`.
- Observe it always returns `0` regardless of data.

**Simple fix:** Implement the DB query and return the sum for the requested month.

---

## Client B (Ocean Rentals)

### B0) All users can see all other tenants' data (root cause)
**Symptom:** Any authenticated user can query and receive revenue data belonging to a different tenant — not just on refresh, but on every request.

**Root cause:** Three compounding failures, all rooted in the same issue — the system never enforces tenant boundaries:

1. **No RLS policies defined** — [`database/schema.sql`](database/schema.sql) enables Row Level Security on `properties` and `reservations` but never creates any `CREATE POLICY` statements. With RLS enabled and zero policies, PostgreSQL denies all access by default for non-superuser roles — but since the backend uses a service role or bypasses RLS, all rows are returned for any tenant.
2. **Cache key has no tenant scope** — [`backend/app/services/cache.py`](backend/app/services/cache.py#L9-L27) caches revenue under `revenue:{property_id}` only. Since `prop-001` exists in both `tenant-a` and `tenant-b` (confirmed in [`database/seed.sql`](database/seed.sql)), the first tenant to request it poisons the cache for the other.
3. **Fallback mock data not tenant-scoped** — [`backend/app/services/reservations.py`](backend/app/services/reservations.py#L88-L108) returns hardcoded values keyed only by `property_id`, so both tenants receive identical numbers from the fallback.

**Impact:** Complete cross-tenant data leakage. Every user can effectively see every other company's revenue figures.

**How to trigger (reliable):**
- Login as `tenant-a` (Sunset) and request `/api/v1/dashboard/summary?property_id=prop-001`.
- Logout and login as `tenant-b` (Ocean), request the same endpoint with the same `property_id=prop-001`.
- The response will contain `tenant-a`'s cached revenue — not `tenant-b`'s.

**Simple fix:**
- Add RLS policies to `schema.sql` restricting rows by `tenant_id` to the authenticated tenant's JWT claim.
- Include `tenant_id` in all cache keys.
- Scope all fallback data and DB queries by `tenant_id`.

---

### B1) Cross-tenant revenue leakage via backend cache key
**Symptom:** Client B sometimes sees Client A revenue after refresh for the same property ID.

**Root cause:** The backend revenue cache key only uses `property_id`, so different tenants sharing a property ID collide and reuse cached data across tenants.

- Cache key: `revenue:{property_id}` (no tenant scoping)
- File: [backend/app/services/cache.py](backend/app/services/cache.py#L9-L27)

**Impact:** Privacy breach (tenant data leakage) and incorrect revenue totals for affected properties.

**How to trigger (reliable):**
- In Swagger, login as Sunset and request `/api/v1/dashboard/summary?property_id=prop-002`.
- Immediately login as Ocean and request the same property ID.
- If the second response matches the first, the cache is cross-tenant.

**Simple fix:** Include `tenant_id` in the cache key (and in invalidation if used).

---

## Other blocking issues

### O1) Session recovery crash breaks tenant context (frontend)
**Symptom:** Console error: `TypeError: Cannot read properties of undefined (reading 'split')`, followed by `[API SECURITY] No valid tenant ID - bypassing cache`.

**Root cause:** `SessionRecovery` assumes `VITE_SUPABASE_URL` is defined and calls `.split` on it. If missing, session recovery fails and tenant ID cannot be resolved consistently.

- File: [frontend/src/utils/sessionRecovery.ts](frontend/src/utils/sessionRecovery.ts#L74-L75)

**Impact:** Tenant context may not be available during API calls, leading to bypassed client-side caching and inconsistent behavior.

**How to trigger (reliable):**
- Start the frontend without `VITE_SUPABASE_URL`, then refresh the page and check console logs.

**Simple fix:** Guard against missing env vars and fail gracefully; ensure `VITE_SUPABASE_URL` is set.

---

### O2) Login crash due to auth response shape mismatch (frontend)
**Symptom:** `Login error: TypeError: Cannot read properties of undefined (reading 'session')` after submitting the login form.

**Root cause:** The app uses a local auth client that returns `{ user, session, error }`, but the new AuthContext expects Supabase’s `{ data, error }` shape and reads `data.session`, which is undefined.

- AuthContext expects `data.session`
- File: [frontend/src/contexts/AuthContext.new.tsx](frontend/src/contexts/AuthContext.new.tsx#L239-L255)
- Local auth client returns `{ user, session, error }`
- File: [frontend/src/lib/localAuthClient.ts](frontend/src/lib/localAuthClient.ts#L79-L131)

**Impact:** Login fails even with valid credentials, blocking access to the dashboard and preventing tenant context from being set.

**How to trigger (reliable):**
- Attempt login in the UI while using the local auth client; see console error.

**Simple fix:** Normalize auth response shape (return `{ data: { user, session }, error }`) or update callers to handle both shapes.

---

### O3) Reload returns to login after sign-in
**Symptom:** Reloading the app sends the user back to `/login` even after a successful login.

**Root cause:** Session recovery fails (see bug O1), so `getSession()` returns null and the auth state resets.

**Impact:** Users cannot maintain an active session across reloads.

**How to trigger (reliable):**
- Login, then hard-refresh the page; observe redirect to login.

**Simple fix:** Fix session recovery and ensure auth state initializes from stored session correctly.

---

### O4) Profile page inaccessible
**Symptom:** `/profile` redirects to `/login` or shows “Failed to load profile.”

**Root cause:** The user is not authenticated due to login/session issues (bugs O1 and O2), so `ProtectedRoute` redirects and profile requests fail with “No active session.”

- Route guard: [frontend/src/components/ProtectedRoute.new.tsx](frontend/src/components/ProtectedRoute.new.tsx#L7-L30)
- Profile API requires session: [frontend/src/services/profileService.ts](frontend/src/services/profileService.ts#L9-L22)

**Impact:** Profile cannot be viewed or edited.

**How to trigger (reliable):**
- Try navigating to `/profile` after a login attempt; see redirect or API error.

**Simple fix:** Resolve login/session issues so `isAuthenticated` is true and a valid access token exists.

---

## Notes
- These issues align with the reported client complaints (cross-tenant data, inaccurate totals, cents-off rounding).
- Fixes should prioritize tenant scoping in caches, precision-safe money handling, and session recovery stability.
