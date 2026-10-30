(function () {
  'use strict';
  const sb = window.supabase.createClient(window.BENI_CONFIG.url, window.BENI_CONFIG.key);
  const $app = document.getElementById('app');
  let lang = 'en'; try { lang = localStorage.getItem('beni_lang') === 'fr' ? 'fr' : 'en'; } catch (e) {}
  const T = (en, fr) => (lang === 'fr' ? fr : en);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const S = { user: null, profile: null, project: null, role: null, page: 'dashboard', mode: 'in', err: '', busy: false };
  const toast = (m) => { const t = document.getElementById('toast'); t.textContent = m; t.className = 'on'; clearTimeout(toast.t); toast.t = setTimeout(() => (t.className = ''), 3200); };
  const setLang = (v) => { lang = v; try { localStorage.setItem('beni_lang', v); } catch (e) {} document.documentElement.lang = v; render(); };
  const fmtD = (d) => (d ? new Date(d).toLocaleDateString(lang === 'fr' ? 'fr-FR' : 'en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '—');
  const fmtDT = (d) => (d ? new Date(d).toLocaleString(lang === 'fr' ? 'fr-FR' : 'en-GB') : '—');
  const errMsg = (e) => (e && e.message ? e.message : String(e));

  const STATUS = {
    draft: ['Draft', 'Brouillon'], internally_reviewed: ['Internally reviewed', 'Revu en interne'], approved_for_issue: ['Approved for issue', 'Approuvé pour émission'],
    formally_issued: ['Formally issued', 'Émis officiellement'], delivery_pending: ['Delivery pending', 'Remise en attente'], delivered: ['Delivered', 'Remis'],
    receipt_confirmed: ['Receipt confirmed', 'Réception confirmée'], response_pending: ['Response pending', 'Réponse en attente'], response_received: ['Response received', 'Réponse reçue'],
    under_assessment: ['Under assessment', 'En cours d’évaluation'], determined: ['Determined', 'Déterminé'], closed: ['Closed', 'Clos']
  };
  const stT = (s) => (STATUS[s] ? T(STATUS[s][0], STATUS[s][1]) : s);
  const URG = { overdue: ['Overdue', 'En retard', 'warn'], due_today: ['Due today', 'Échéance aujourd’hui', 'warn'], approaching: ['Approaching', 'Proche', 'warn'], flagged_for_review: ['Flagged for review', 'À revoir', 'warn'], on_track: ['On track', 'Dans les délais', 'ok'], satisfied: ['Satisfied', 'Satisfait', 'ok'] };

  // ---------- data ----------
  async function loadSession() {
    const { data } = await sb.auth.getSession();
    S.user = data.session ? data.session.user : null;
    if (!S.user) return;
    const p = await sb.from('profiles').select('*').eq('id', S.user.id).maybeSingle();
    S.profile = p.data;
    const m = await sb.from('project_members').select('project_id,role,projects(id,name,location,timezone)').eq('user_id', S.user.id).eq('active', true);
    const rows = (m.data || []);
    if (rows.length) { S.project = rows[0].projects; S.role = rows[0].role; } else { S.project = null; S.role = null; }
  }

  // ---------- auth ----------
  function authView() {
    const up = S.mode === 'up';
    $app.innerHTML = `<div class="auth"><div class="top"><div><b>AIA ADVENTIS INHOUSE AFRICA</b><div style="font-size:12px;color:#cfe0ee">${T('Contractor', 'Entrepreneur')}</div></div>
      <div class="lang" role="group" aria-label="Language"><button aria-pressed="${lang === 'en'}" data-l="en">EN</button><button aria-pressed="${lang === 'fr'}" data-l="fr">FR</button></div></div>
      <div class="box"><h1>Beni Airport Project</h1><h2>${T('Terminal and Control Tower', 'Terminal et tour de contrôle')}</h2>
      <form id="af" novalidate><div style="font-weight:800">${up ? T('Create your account', 'Créer votre compte') : T('Sign in', 'Connexion')}</div>
      ${up ? `<label for="fn">${T('Full name', 'Nom complet')}</label><input id="fn" autocomplete="name">` : ''}
      <label for="em">${T('Email', 'Courriel')}</label><input id="em" type="email" autocomplete="username" autocapitalize="none">
      <label for="pw">${T('Password', 'Mot de passe')}</label><input id="pw" type="password" autocomplete="${up ? 'new-password' : 'current-password'}">
      <button class="btn wide" type="submit" ${S.busy ? 'disabled' : ''}>${up ? T('Create account', 'Créer le compte') : T('Sign in', 'Se connecter')}</button>
      ${S.err ? `<div class="err" role="alert">${esc(S.err)}</div>` : ''}
      <button class="link" type="button" id="sw">${up ? T('I already have an account', 'J’ai déjà un compte') : T('Create an account', 'Créer un compte')}</button>
      ${up ? `<div style="font-size:12px;color:#cfe0ee;margin-top:8px">${T('Use at least 10 characters. You may need to confirm your email before signing in.', 'Utilisez au moins 10 caractères. Vous devrez peut-être confirmer votre courriel avant de vous connecter.')}</div>` : ''}
      </form><div style="margin-top:22px;font-size:13px;color:#cfe0ee">${T('Project Manager: Andrew Mwaura · Assistant Project Manager: Bethwell', 'Chef de projet : Andrew Mwaura · Chef de projet adjoint : Bethwell')}</div></div></div>`;
    $app.querySelectorAll('[data-l]').forEach((b) => (b.onclick = () => setLang(b.dataset.l)));
    document.getElementById('sw').onclick = () => { S.mode = up ? 'in' : 'up'; S.err = ''; render(); };
    document.getElementById('af').onsubmit = async (e) => {
      e.preventDefault();
      const em = document.getElementById('em').value.trim(), pw = document.getElementById('pw').value;
      if (!em || !pw) { S.err = T('Enter your email and password.', 'Saisissez votre courriel et votre mot de passe.'); return render(); }
      S.busy = true; S.err = '';
      let r;
      if (up) {
        if (pw.length < 10) { S.busy = false; S.err = T('Password must have at least 10 characters.', 'Le mot de passe doit comporter au moins 10 caractères.'); return render(); }
        r = await sb.auth.signUp({ email: em, password: pw, options: { data: { full_name: (document.getElementById('fn').value || '').trim() } } });
        if (!r.error && !r.data.session) { S.busy = false; S.mode = 'in'; S.err = ''; render(); return toast(T('Account created. Check your email to confirm it, then sign in.', 'Compte créé. Confirmez-le par courriel, puis connectez-vous.')); }
      } else r = await sb.auth.signInWithPassword({ email: em, password: pw });
      S.busy = false;
      if (r.error) { S.err = T('Could not sign in: ', 'Connexion impossible : ') + errMsg(r.error); return render(); }
      await loadSession(); render();
    };
  }

  // ---------- setup ----------
  function setupView() {
    const can = S.profile && S.profile.can_create_projects;
    $app.innerHTML = `<div class="auth"><div class="box"><h1>${T('Welcome', 'Bienvenue')}</h1>
    <form id="pf" style="max-width:480px">${can ? `<div style="font-weight:800">${T('Create the project', 'Créer le projet')}</div>
      <label for="pn">${T('Project name', 'Nom du projet')}</label><input id="pn" value="BENI Airport DRC – Terminal and Control Tower">
      <label for="pl">${T('Location', 'Lieu')}</label><input id="pl" value="Beni, Democratic Republic of Congo">
      <button class="btn wide" type="submit">${T('Create project', 'Créer le projet')}</button>
      <div style="font-size:12px;color:#cfe0ee;margin-top:8px">${T('You become the Project Administrator. Contract dates and values stay blank until you enter them.', 'Vous devenez administrateur du projet. Les dates et valeurs du contrat restent vides tant que vous ne les saisissez pas.')}</div>`
      : `<div>${T('Your account is not yet added to a project. Ask the Project Administrator to add you, then sign in again.', 'Votre compte n’est pas encore ajouté à un projet. Demandez à l’administrateur de vous ajouter, puis reconnectez-vous.')}</div>`}
      ${S.err ? `<div class="err" role="alert">${esc(S.err)}</div>` : ''}
      <button class="link" type="button" id="so">${T('Sign out', 'Se déconnecter')}</button></form></div></div>`;
    document.getElementById('so').onclick = signOut;
    const f = document.getElementById('pf');
    if (can) f.onsubmit = async (e) => {
      e.preventDefault();
      const r = await sb.rpc('create_project', { p_name: document.getElementById('pn').value.trim(), p_location: document.getElementById('pl').value.trim() });
      if (r.error) { S.err = errMsg(r.error); return render(); }
      await loadSession(); render(); toast(T('Project created.', 'Projet créé.'));
    };
  }
  async function signOut() { await sb.auth.signOut(); S.user = S.profile = S.project = null; render(); }

  // ---------- shell ----------
  const PAGES = [['dashboard', 'Dashboard', 'Tableau de bord'], ['notices', 'Notices', 'Notifications officielles'], ['deadlines', 'Deadlines', 'Délais'], ['report', 'Monthly Report', 'Rapport mensuel'], ['team', 'Team', 'Équipe']];
  function shell(title, lead, body) {
    $app.innerHTML = `<div class="shell"><aside class="side"><div class="flag"></div><div class="brand">BENI Airport DRC</div><div class="sub">${esc(S.project.name)}</div>
      <nav aria-label="Main">${PAGES.map((p) => `<a href="#/${p[0]}" ${S.page === p[0] ? 'aria-current="page"' : ''}>${T(p[1], p[2])}</a>`).join('')}</nav>
      <div class="lang" role="group" aria-label="Language"><button aria-pressed="${lang === 'en'}" data-l="en">EN</button><button aria-pressed="${lang === 'fr'}" data-l="fr">FR</button></div>
      <div class="me">${esc((S.profile && S.profile.full_name) || S.user.email)}<br>${esc(S.role || '')}<br><button class="link" id="so" type="button">${T('Sign out', 'Se déconnecter')}</button></div></aside>
      <main><h1>${title}</h1><p class="lead">${lead}</p>${body}</main></div>`;
    $app.querySelectorAll('[data-l]').forEach((b) => (b.onclick = () => setLang(b.dataset.l)));
    document.getElementById('so').onclick = signOut;
  }
  const loading = (t) => shell(t, T('Loading…', 'Chargement…'), '');
  const failBody = (e) => `<div class="err" role="alert">${esc(errMsg(e))}</div>`;

  // ---------- pages ----------
  async function dashboard() {
    loading(T('Dashboard', 'Tableau de bord'));
    const r = await sb.rpc('project_dashboard', { p: S.project.id });
    if (r.error) return shell(T('Dashboard', 'Tableau de bord'), '', failBody(r.error));
    const d = r.data, nv = (v, suf) => (v == null ? T('Not set', 'Non défini') : v + (suf || ''));
    const card = (n, l) => `<div class="card stat"><b>${esc(n)}</b><span>${l}</span></div>`;
    shell(T('Dashboard', 'Tableau de bord'), esc(S.project.name),
      `${d.rules_approved === 0 ? `<div class="note"><b>${T('No deadline rules approved yet.', 'Aucune règle de délai approuvée.')}</b> ${T('Deadlines appear only from rules that have been verified and approved against the contract.', 'Les délais n’apparaissent qu’à partir de règles vérifiées et approuvées au regard du contrat.')}</div>` : ''}
      <div class="grid">${card(nv(d.planned_completion_date && fmtD(d.planned_completion_date)), T('Planned completion', 'Achèvement prévu'))}${card(nv(d.days_elapsed), T('Days elapsed', 'Jours écoulés'))}${card(nv(d.days_remaining), T('Days remaining', 'Jours restants'))}
      ${card(d.draft_notices, T('Draft notices', 'Notifications en brouillon'))}${card(d.open_notices, T('Open notices', 'Notifications ouvertes'))}${card(d.deadlines_overdue, T('Overdue deadlines', 'Délais dépassés'))}
      ${card(d.deadlines_due_within_7_days, T('Due within 7 days', 'Échéance sous 7 jours'))}${card(d.rules_approved + ' / ' + d.rules_total, T('Rules approved', 'Règles approuvées'))}${card(d.documents, T('Documents', 'Documents'))}</div>`);
  }

  const APPROVERS = ['project_manager', 'contract_manager', 'project_administrator'];
  const ISSUERS = ['project_manager', 'contract_manager', 'assistant_project_manager', 'project_administrator', 'engineer', 'contractor_rep', 'employer_rep'];
  async function notices() {
    loading(T('Notices', 'Notifications officielles'));
    const r = await sb.from('notices').select('*').eq('project_id', S.project.id).order('created_at', { ascending: false });
    if (r.error) return shell(T('Notices', 'Notifications officielles'), '', failBody(r.error));
    const rows = r.data || [];
    const act = (n) => {
      if (n.status === 'draft') return `<button class="btn small ghost" data-a="review" data-id="${n.id}">${T('Mark reviewed', 'Marquer revu')}</button>`;
      if (n.status === 'internally_reviewed') return APPROVERS.includes(S.role) ? `<button class="btn small" data-a="approve" data-id="${n.id}">${T('Approve for issue', 'Approuver pour émission')}</button>` : T('Awaiting approval', 'En attente d’approbation');
      if (n.status === 'approved_for_issue') return ISSUERS.includes(S.role) ? `<button class="btn small" data-a="issue" data-id="${n.id}">${T('Record as issued', 'Enregistrer comme émis')}</button>` : T('Awaiting issue', 'En attente d’émission');
      return '';
    };
    shell(T('Notices', 'Notifications officielles'), T('A draft is not an issued notice. Issuing here records the notice; it does not send it to anyone.', 'Un brouillon n’est pas une notification émise. Émettre ici enregistre la notification ; rien n’est envoyé.'),
      `<div class="card" style="margin-bottom:16px"><b>${T('New draft notice', 'Nouveau brouillon')}</b><form class="f" id="nf" style="margin-top:10px">
        <div class="full"><label for="nt">${T('Title', 'Titre')}</label><input id="nt" required></div>
        <div><label for="nc">${T('Category', 'Catégorie')}</label><input id="nc"></div><div><label for="ncl">${T('Contract clause', 'Clause du contrat')}</label><input id="ncl"></div>
        <div><label for="ni">${T('From', 'De')}</label><input id="ni"></div><div><label for="nr">${T('To', 'À')}</label><input id="nr"></div>
        <div><label for="ne">${T('Event date and time', 'Date et heure de l’événement')}</label><input id="ne" type="datetime-local"></div><div><label for="na">${T('Date and time became aware', 'Date et heure de prise de connaissance')}</label><input id="na" type="datetime-local"></div>
        <div class="full"><label for="nd">${T('Description', 'Description')}</label><textarea id="nd" rows="3"></textarea></div>
        <div class="full"><button class="btn" type="submit">${T('Save draft', 'Enregistrer le brouillon')}</button></div></form></div>
      <div class="tw"><table><thead><tr><th>Ref</th><th>${T('Title', 'Titre')}</th><th>${T('Clause', 'Clause')}</th><th>${T('Status', 'Statut')}</th><th>${T('Issued', 'Émis')}</th><th></th></tr></thead><tbody>
      ${rows.length ? rows.map((n) => `<tr><td>${esc(n.ref)}</td><td>${esc(n.title)}<div style="color:#4a5a6e;font-size:12px">${esc(n.initiating_party || '')}${n.receiving_party ? ' → ' + esc(n.receiving_party) : ''}</div></td><td>${esc(n.clause || '—')}</td><td><span class="pill ${n.status === 'draft' ? '' : 'ok'}">${esc(stT(n.status))}</span></td><td>${fmtDT(n.issued_at)}</td><td>${act(n)}</td></tr>`).join('') : `<tr><td colspan="6">${T('No notices yet. Save your first draft above.', 'Aucune notification. Enregistrez un premier brouillon ci-dessus.')}</td></tr>`}</tbody></table></div>`);
    const iso = (id) => { const v = document.getElementById(id).value; return v ? new Date(v).toISOString() : null; };
    document.getElementById('nf').onsubmit = async (e) => {
      e.preventDefault();
      const title = document.getElementById('nt').value.trim(); if (!title) return toast(T('Enter a title.', 'Saisissez un titre.'));
      const ins = await sb.from('notices').insert({ project_id: S.project.id, title, category: document.getElementById('nc').value || null, clause: document.getElementById('ncl').value || null, initiating_party: document.getElementById('ni').value || null, receiving_party: document.getElementById('nr').value || null, event_at: iso('ne'), aware_at: iso('na'), description: document.getElementById('nd').value || null }).select().single();
      if (ins.error) return toast(errMsg(ins.error));
      toast(T('Draft saved as ', 'Brouillon enregistré : ') + ins.data.ref); notices();
    };
    $app.querySelectorAll('[data-a]').forEach((b) => (b.onclick = async () => {
      const a = b.dataset.a, id = b.dataset.id; let patch;
      if (a === 'review') patch = { status: 'internally_reviewed' };
      if (a === 'approve') patch = { status: 'approved_for_issue', approver: S.user.id, approved_at: new Date().toISOString() };
      if (a === 'issue') { if (!confirm(T('Record this notice as formally issued? An issued notice cannot be edited afterwards.', 'Enregistrer cette notification comme émise ? Elle ne pourra plus être modifiée.'))) return; patch = { status: 'formally_issued', issued_at: new Date().toISOString() }; }
      const u = await sb.from('notices').update(patch).eq('id', id);
      if (u.error) return toast(errMsg(u.error)); toast(T('Updated.', 'Mis à jour.')); notices();
    }));
  }

  async function deadlines() {
    loading(T('Deadlines', 'Délais'));
    const [d, r] = await Promise.all([sb.from('v_deadlines').select('*').eq('project_id', S.project.id).order('due_date'), sb.from('deadline_rules').select('rule_code,matter,status,clause').eq('project_id', S.project.id).order('rule_code')]);
    if (d.error) return shell(T('Deadlines', 'Délais'), '', failBody(d.error));
    const dl = d.data || [], rules = r.data || [];
    shell(T('Deadlines', 'Délais'), T('Dates come only from rules approved against the contract.', 'Les dates proviennent uniquement de règles approuvées au regard du contrat.'),
      `<h2 style="font-size:18px">${T('Contractual deadlines', 'Délais contractuels')}</h2><div class="tw"><table><thead><tr><th>${T('Deadline', 'Délai')}</th><th>${T('Clause', 'Clause')}</th><th>${T('Due', 'Échéance')}</th><th>${T('Days left', 'Jours restants')}</th><th>${T('Status', 'Statut')}</th></tr></thead><tbody>
      ${dl.length ? dl.map((x) => { const u = URG[x.urgency] || [x.urgency, x.urgency, '']; return `<tr><td>${esc(x.title)}</td><td>${esc(x.clause || '—')}</td><td>${fmtD(x.due_date)}</td><td>${x.days_remaining == null ? '—' : esc(x.days_remaining)}</td><td><span class="pill ${u[2]}">${T(u[0], u[1])}</span></td></tr>`; }).join('') : `<tr><td colspan="5">${T('No deadlines yet. They are created when a notice is linked to an approved rule.', 'Aucun délai. Ils sont créés lorsqu’une notification est liée à une règle approuvée.')}</td></tr>`}</tbody></table></div>
      <h2 style="font-size:18px;margin-top:22px">${T('Deadline rules', 'Règles de délai')}</h2><div class="tw"><table><thead><tr><th>Code</th><th>${T('Matter', 'Objet')}</th><th>${T('Clause', 'Clause')}</th><th>${T('Status', 'Statut')}</th></tr></thead><tbody>
      ${rules.map((x) => `<tr><td>${esc(x.rule_code)}</td><td>${esc(x.matter)}</td><td>${esc(x.clause || '—')}</td><td><span class="pill ${x.status === 'approved' ? 'ok' : ''}">${esc(x.status)}</span></td></tr>`).join('')}</tbody></table></div>`);
  }

  async function report() {
    loading(T('Monthly Report', 'Rapport mensuel'));
    const r = await sb.from('monthly_reports').select('id,ref,period_start,period_end,due_date,status,issued_at').eq('project_id', S.project.id).order('period_start', { ascending: false });
    if (r.error) return shell(T('Monthly Report', 'Rapport mensuel'), '', failBody(r.error));
    const rows = r.data || [];
    shell(T('Monthly Report', 'Rapport mensuel'), T('Sub-Clause 4.20 progress report. The system fills what it knows; people write and sign the rest.', 'Rapport d’avancement (Sous-Clause 4.20). Le système remplit ce qu’il connaît ; les personnes rédigent et signent le reste.'),
      `<p><button class="btn" id="gen">${T('Generate this month’s report', 'Générer le rapport du mois')}</button></p>
      <div class="tw"><table><thead><tr><th>Ref</th><th>${T('Period', 'Période')}</th><th>${T('Due', 'Échéance')}</th><th>${T('Status', 'Statut')}</th><th>${T('Issued', 'Émis')}</th></tr></thead><tbody>
      ${rows.length ? rows.map((x) => `<tr><td>${esc(x.ref)}</td><td>${fmtD(x.period_start)} – ${fmtD(x.period_end)}</td><td>${fmtD(x.due_date)}</td><td><span class="pill">${esc(x.status)}</span></td><td>${fmtDT(x.issued_at)}</td></tr>`).join('') : `<tr><td colspan="5">${T('No reports yet.', 'Aucun rapport.')}</td></tr>`}</tbody></table></div>
      <p style="color:#4a5a6e;font-size:13px">${T('Writing sections and the three-person sign-off are added in the next release.', 'La rédaction des sections et la signature à trois personnes seront ajoutées dans la prochaine version.')}</p>`);
    document.getElementById('gen').onclick = async () => { const g = await sb.rpc('generate_monthly_report', { p: S.project.id }); if (g.error) return toast(errMsg(g.error)); toast(T('Report generated.', 'Rapport généré.')); report(); };
  }

  async function team() {
    loading(T('Team', 'Équipe'));
    const r = await sb.from('project_members').select('role,organization,active,user_id').eq('project_id', S.project.id);
    if (r.error) return shell(T('Team', 'Équipe'), '', failBody(r.error));
    const ids = (r.data || []).map((x) => x.user_id);
    const p = ids.length ? await sb.from('profiles').select('id,full_name,email').in('id', ids) : { data: [] };
    const nm = {}; (p.data || []).forEach((x) => (nm[x.id] = x));
    shell(T('Team', 'Équipe'), T('People with access to this project.', 'Personnes ayant accès à ce projet.'),
      `<div class="tw"><table><thead><tr><th>${T('Name', 'Nom')}</th><th>${T('Role', 'Rôle')}</th><th>${T('Organisation', 'Organisation')}</th><th>${T('Active', 'Actif')}</th></tr></thead><tbody>${(r.data || []).map((x) => `<tr><td>${esc((nm[x.user_id] || {}).full_name || (nm[x.user_id] || {}).email || '—')}</td><td>${esc(x.role)}</td><td>${esc(x.organization || '—')}</td><td>${x.active ? '✓' : '—'}</td></tr>`).join('')}</tbody></table></div>
      <p style="color:#4a5a6e;font-size:13px">${T('Adding team members from this screen is part of the next release.', 'L’ajout de membres depuis cet écran sera dans la prochaine version.')}</p>`);
  }

  // ---------- router ----------
  const ROUTES = { dashboard, notices, deadlines, report, team };
  async function render() {
    document.documentElement.lang = lang;
    if (!S.user) return authView();
    if (!S.project) return setupView();
    const h = (location.hash || '').replace('#/', '');
    S.page = ROUTES[h] ? h : 'dashboard';
    try { await ROUTES[S.page](); } catch (e) { shell(T('Error', 'Erreur'), '', failBody(e)); }
  }
  window.addEventListener('hashchange', render);
  sb.auth.onAuthStateChange((ev) => { if (ev === 'SIGNED_OUT') { S.user = null; } });
  loadSession().then(render);
})();
