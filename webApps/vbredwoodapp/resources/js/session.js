/* O2C Timesheet Module — sign-in transport and token storage */

define([], () => {
  'use strict';

  /**
   * Everything that talks to oc.time.auth, in one place.
   *
   * These are plain fetch calls rather than callRest because the auth endpoints
   * are not part of the module's data surface: they are what establishes the
   * identity the rest of the calls carry, and they must work before any service
   * context exists. The main O2C application does the same, so the two apps'
   * sign-in behaviour is comparable line for line.
   *
   * The token is a bearer credential. It lives in localStorage so a refresh does
   * not force a re-login, and it is cleared on logout, on expiry, and on any
   * password change (the server drops the sessions too, so a token that outlives
   * its credential stops working even if the browser still holds it).
   */

  const KEY_TOKEN = 'oc_time_session_token';

  function authUrl(baseUrl, path) {
    return String(baseUrl || '').replace(/\/+$/, '') + '/oc/time/auth/' + path;
  }

  async function readJson(resp) {
    // A 500 from ORDS can arrive as HTML, and letting that throw would report a
    // parse error instead of the failure the user actually hit.
    try {
      return await resp.json();
    } catch (e) {
      return null;
    }
  }

  return {

    readToken() {
      try {
        return localStorage.getItem(KEY_TOKEN) || '';
      } catch (e) {
        return '';        // storage disabled — the session simply won't persist
      }
    },

    writeToken(token) {
      try {
        localStorage.setItem(KEY_TOKEN, token);
      } catch (e) {
        // Non-fatal: the user stays signed in for this tab, and is asked again
        // after a refresh.
      }
    },

    clearToken() {
      try {
        localStorage.removeItem(KEY_TOKEN);
      } catch (e) {
        // Nothing to clear if storage is unavailable.
      }
    },

    /**
     * POST login. Resolves to the session on success; throws an Error carrying
     * the server's own message otherwise, because those messages are written to
     * be shown ("Set your password before signing in", not "HTTP 403").
     */
    async login(baseUrl, email, password) {
      const resp = await fetch(authUrl(baseUrl, 'login'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
      });
      const data = await readJson(resp);

      if (!resp.ok) {
        const err = new Error((data && data.error) || 'Sign-in failed. Please try again.');
        err.status = resp.status;
        err.needsPassword = !!(data && data.status === 'Invited');
        throw err;
      }
      return {
        token:        data.token,
        userId:       data.userId,
        employeeId:   data.employeeId || '',
        employeeName: data.employeeName || '',
        fullName:     data.employeeName || email,
        role:         data.role,
        email,
      };
    },

    /**
     * GET session/:token. Resolves to the identity, or null when the token is
     * expired, revoked or unknown — all three are the same thing to the caller.
     * Throws only when the service itself could not be reached.
     */
    async validateToken(baseUrl, token) {
      const resp = await fetch(
        authUrl(baseUrl, 'session/' + encodeURIComponent(token)),
        { headers: { Accept: 'application/json' } });

      if (!resp.ok) {
        if (resp.status >= 500) {
          throw new Error('The timesheet service returned ' + resp.status + '.');
        }
        return null;
      }

      const data = await readJson(resp);
      // A collection feed answers 200 with an empty items array for a token it
      // does not recognise, so an empty result is the normal "not valid" path.
      if (!data || !data.items || !data.items.length) {
        return null;
      }
      const r = data.items[0];

      return {
        userId:         r.user_id,
        email:          r.email,
        role:           r.app_role,
        employeeId:     r.employee_id || '',
        employeeName:   r.employee_name || '',
        fullName:       r.employee_name || r.email,
        managerEmpId:   r.manager_emp_id || '',
        workerType:     r.worker_type || 'Employee',
        stdHoursPerDay: r.std_hours_per_day || 8,
        totalAllocPct:  r.total_alloc_pct || 0,
        openPeriodId:   r.open_period_id || null,
      };
    },

    /**
     * POST logout. Never throws: the caller has already decided to sign out, and
     * failing to tell the server is not a reason to keep the user signed in. The
     * token is dropped locally either way and expires server-side within 24h.
     */
    async logout(baseUrl, token) {
      if (!token) {
        return;
      }
      try {
        await fetch(authUrl(baseUrl, 'logout'), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ token }),
        });
      } catch (e) {
        // Deliberately swallowed — see above.
      }
    },

    /**
     * Write a resolved identity into the application variables.
     *
     * Shared by the two ways a session begins — restored from a stored token on
     * shell entry, or created by the login form — so that the two cannot end up
     * populating different subsets of the context that every page then reads.
     */
    apply($application, identity, token) {
      const v = $application.variables;

      v.isLoggedIn     = true;
      v.sessionToken   = token;
      v.currentUserId  = identity.userId;
      v.currentEmail   = identity.email;
      v.currentRole    = identity.role;
      v.userName       = identity.fullName;

      v.employeeId     = identity.employeeId || '';
      v.employeeName   = identity.employeeName || identity.fullName;
      v.managerEmpId   = identity.managerEmpId || '';
      v.workerType     = identity.workerType || 'Employee';
      v.stdHoursPerDay = identity.stdHoursPerDay || 8;
      v.totalAllocPct  = identity.totalAllocPct || 0;
      v.openPeriodId   = identity.openPeriodId || null;

      // A manager reviews their own team until they say otherwise (ACT-011).
      v.actingManagerId = identity.employeeId || '';
    },

    /** Undo apply(). Every field, so nothing of the last user survives. */
    clear($application) {
      const v = $application.variables;

      v.isLoggedIn      = false;
      v.sessionToken    = '';
      v.currentUserId   = null;
      v.currentEmail    = '';
      v.currentRole     = '';
      v.userName        = '';

      v.employeeId      = '';
      v.employeeName    = '';
      v.managerEmpId    = '';
      v.workerType      = 'Employee';
      v.stdHoursPerDay  = 8;
      v.totalAllocPct   = 0;
      v.openPeriodId    = null;
      v.actingManagerId = '';

      // Period context too: leaving the last user's month selected would show
      // the next person a period they may not be entitled to see.
      v.selectedPeriodId     = null;
      v.selectedPeriodName   = '';
      v.periodEditable       = 'N';
      v.adjustmentAllowed    = 'N';
      v.selectedProjectId    = null;
      v.selectedProjectName  = '';
      v.selectedEmployeeId   = '';
      v.selectedEmployeeName = '';
      v.selectedWeekId       = null;
    },

    /** POST set-password. currentPassword is omitted for an Invited account. */
    async setPassword(baseUrl, email, currentPassword, newPassword) {
      const resp = await fetch(authUrl(baseUrl, 'set-password'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          email,
          currentPassword: currentPassword || null,
          newPassword,
          actor: email,
        }),
      });
      const data = await readJson(resp);

      if (!resp.ok) {
        const err = new Error((data && data.error) || 'Could not set the password.');
        err.status = resp.status;
        throw err;
      }
      return data;
    },
  };
});
