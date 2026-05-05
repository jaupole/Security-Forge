// helloworld-frontend — Phase 9 demo client.
//
// What this script does:
//   1. Fetch /api/me. On 401, redirect to /login (BFF starts the OIDC flow).
//   2. On 200, render the user's name + fetch /api/document/welcome.
//   3. On 200, render the document and offer Edit if the user has write access.
//   4. On 403 from /api/document/welcome, render the friendly forbidden state.
//
// What this script does NOT do (intentionally):
//   - Read or write OAuth tokens. The browser holds NONE.
//   - Decode JWTs.
//   - Talk to Keycloak directly.
//   - Talk to the backend directly.
//
// All API calls go to the same origin. The BFF holds the session, mints
// the DPoP-bound JWT, and proxies to helloworld-backend.

(function () {
    'use strict';

    const $ = (id) => document.getElementById(id);

    const statusEl = $('status');
    const welcomeEl = $('welcome');
    const docEl = $('document');
    const forbiddenEl = $('forbidden');

    function show(el) { el.hidden = false; }
    function hide(el) { el.hidden = true; }

    function setStatus(msg, kind) {
        statusEl.textContent = msg;
        statusEl.className = kind || '';
    }

    async function loadMe() {
        const res = await fetch('/api/me', {
            credentials: 'same-origin',
            headers: { 'Accept': 'application/json' },
        });
        if (res.status === 401) {
            window.location.assign('/login?next=' + encodeURIComponent(window.location.pathname));
            return null;
        }
        if (!res.ok) {
            throw new Error('GET /api/me ' + res.status);
        }
        return res.json();
    }

    async function loadDocument() {
        const res = await fetch('/api/document/welcome', {
            credentials: 'same-origin',
            headers: { 'Accept': 'application/json' },
        });
        if (res.status === 401) {
            window.location.assign('/login?next=' + encodeURIComponent(window.location.pathname));
            return null;
        }
        if (res.status === 403) {
            return { forbidden: true };
        }
        if (!res.ok) {
            throw new Error('GET /api/document/welcome ' + res.status);
        }
        return res.json();
    }

    async function saveDocument(content) {
        const res = await fetch('/api/document/welcome', {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({ content }),
        });
        if (res.status === 401) {
            window.location.assign('/login?next=' + encodeURIComponent(window.location.pathname));
            return null;
        }
        if (res.status === 403) {
            return { forbidden: true };
        }
        if (!res.ok) {
            throw new Error('POST /api/document/welcome ' + res.status);
        }
        return res.json();
    }

    function renderDocument(doc, canEdit) {
        $('doc-title').textContent = doc.id;
        $('doc-owner').textContent = doc.owner;
        $('doc-updated').textContent = new Date(doc.updated_at).toLocaleString();
        $('doc-content').textContent = doc.content;
        if (canEdit) {
            show($('edit-btn'));
        } else {
            hide($('edit-btn'));
        }
    }

    function wireEditFlow(currentDoc, displayName) {
        const editBtn = $('edit-btn');
        const saveBtn = $('save-btn');
        const cancelBtn = $('cancel-btn');
        const editor = $('doc-editor');
        const content = $('doc-content');
        const feedback = $('action-feedback');

        editBtn.addEventListener('click', () => {
            editor.value = content.textContent;
            hide(content);
            hide(editBtn);
            show(editor);
            show(saveBtn);
            show(cancelBtn);
            feedback.textContent = '';
        });

        cancelBtn.addEventListener('click', () => {
            show(content);
            show(editBtn);
            hide(editor);
            hide(saveBtn);
            hide(cancelBtn);
        });

        saveBtn.addEventListener('click', async () => {
            saveBtn.disabled = true;
            feedback.textContent = 'Saving…';
            try {
                const result = await saveDocument(editor.value);
                if (!result) return;
                if (result.forbidden) {
                    feedback.textContent = 'Save denied (you can view but not edit).';
                    return;
                }
                content.textContent = editor.value;
                show(content);
                show(editBtn);
                hide(editor);
                hide(saveBtn);
                hide(cancelBtn);
                feedback.textContent = 'Saved.';
            } catch (e) {
                feedback.textContent = 'Save failed: ' + e.message;
            } finally {
                saveBtn.disabled = false;
            }
        });
    }

    async function logout() {
        try {
            await fetch('/logout', { method: 'POST', credentials: 'same-origin' });
        } catch (_) { /* best effort */ }
        window.location.assign('/');
    }

    async function main() {
        try {
            const me = await loadMe();
            if (!me) return;

            $('user-name').textContent = me.sub.slice(0, 8) + '…';
            show(welcomeEl);

            const doc = await loadDocument();
            if (!doc) return;

            if (doc.forbidden) {
                hide(statusEl);
                show(forbiddenEl);
                return;
            }

            // The contract for "can edit": we don't know without trying.
            // Render Edit unconditionally; the backend rejects with 403 if
            // the SpiceDB check denies it. (Avoiding a separate "may I edit"
            // probe keeps the demo's permission flow on a single critical
            // path per request.)
            renderDocument(doc, true);
            wireEditFlow(doc, me.sub);

            hide(statusEl);
            show(docEl);

            $('logout-btn').addEventListener('click', logout);
        } catch (e) {
            setStatus('Failed: ' + e.message, 'error');
        }
    }

    document.addEventListener('DOMContentLoaded', main);
})();
