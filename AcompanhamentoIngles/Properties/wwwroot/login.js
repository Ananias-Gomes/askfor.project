'use strict';
const $ = s => document.querySelector(s);
const form = $('#form-login'), status = $('#status-login'), botao = $('#entrar');

// Quem já tem sessão vai direto para a página principal.
fetch('/api/me', { credentials: 'same-origin' }).then(r => { if (r.ok) location.replace('index.html'); }).catch(() => {});

form.addEventListener('submit', async e => {
  e.preventDefault();
  status.textContent = '';

  const email = $('#email'), senha = $('#senha');
  const okEmail = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.value.trim());
  const okSenha = senha.value.length > 0;
  for (const [el, ok] of [[email, okEmail], [senha, okSenha]]) {
    const er = $('#erro-' + el.id);
    el.setAttribute('aria-invalid', !ok);
    er.hidden = ok;
    ok ? el.removeAttribute('aria-describedby') : el.setAttribute('aria-describedby', er.id);
  }
  if (!okEmail) return email.focus();
  if (!okSenha) return senha.focus();

  botao.disabled = true;
  status.style.color = 'inherit';
  status.textContent = 'Entrando…';
  try {
    const r = await fetch('/api/login', {
      method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email.value.trim(), senha: senha.value, papel: form.elements.papel.value })
    });
    if (r.ok) { location.replace('index.html'); return; }   // destino fixo: nunca vem da URL (evita redirecionamento aberto)
    const j = await r.json().catch(() => ({}));
    status.style.color = 'var(--erro)';
    status.textContent = 'Erro: ' + (j.erro || (r.status === 429 ? 'muitas tentativas. Aguarde um minuto.' : 'não foi possível entrar. Tente novamente.'));
    senha.value = '';
    senha.focus();
  } catch (_) {
    status.style.color = 'var(--erro)';
    status.textContent = 'Erro: sem conexão com o servidor. Confira se a API está rodando.';
  } finally {
    botao.disabled = false;
  }
});