'use strict';
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const root = document.documentElement;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const norm = s => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
const MES = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
const fmtMes = m => m ? `${MES[+m.slice(5) - 1]}/${m.slice(0, 4)}` : '';
const SKILLS = ['Grammar', 'Vocabulary', 'Writing', 'Speaking', 'Reading', 'Listening'];   // mesma ordem dos Ids 1..6 no SQL
const reduz = matchMedia('(prefers-reduced-motion:reduce)').matches;

// Cores do gráfico por modo (inspiradas em Okabe-Ito). Além da cor, cada habilidade tem traço e marcador próprios.
const PAL = {
  padrao: ['#0072B2', '#D55E00', '#009E73', '#CC79A7', '#B8860B', '#6B5B95'],
  protanopia: ['#0072B2', '#C78500', '#3C8DC9', '#8C7A00', '#7B4FA0', '#5F6B7A'],
  deuteranopia: ['#0072B2', '#C78500', '#3C8DC9', '#8C7A00', '#7B4FA0', '#5F6B7A'],
  tritanopia: ['#C0392B', '#00838F', '#B5367F', '#8A5A00', '#2E7D32', '#5F6B7A']
};
const TRACO = [[], [6, 3], [2, 3], [10, 3, 2, 3], [], [4, 4]];
const MARCA = ['circle', 'triangle', 'rect', 'rectRot', 'star', 'crossRot'];

let user = null, alunos = [], avals = [], evol = [], grafico = null, dif = 'Todas', q = '';

async function api(url, opts) {
  const r = await fetch(url, { credentials: 'same-origin', ...opts, headers: { 'Content-Type': 'application/json' } });
  if (r.status === 401 && user) location.replace('login.html');   // sessão expirou
  return r;
}
async function erroDe(r) {
  if (r.status === 429) return 'Muitas tentativas. Aguarde um minuto e tente de novo.';
  if (r.status === 403) return 'Seu perfil não tem permissão para esta ação.';
  const j = await r.json().catch(() => ({}));
  return Object.values(j.errors || {}).flat().join(' ') || j.erro || 'Não foi possível concluir. Tente novamente.';
}

/* ---------- Sessão e áreas por perfil (o servidor também confere cada rota) ---------- */
function aplicarPapel() {
  $$('[data-papel]').forEach(el => {
    const p = el.dataset.papel;
    el.hidden = !(p === 'visitante' ? !user : p === 'logado' ? !!user : user?.papel === p);
  });
}
async function init() {
  const r = await fetch('/api/me', { credentials: 'same-origin' }).catch(() => null);
  if (r?.ok) user = await r.json();
  aplicarPapel();
  if (!user) return;
  $('#ola').textContent = `Olá, ${user.nome}`;
  montarFiltros();
  await Promise.all([carregarAlunos(), carregarAvals()]);
  await carregarEvolucao();
}
$('#sair').addEventListener('click', async () => {
  await fetch('/api/logout', { method: 'POST', credentials: 'same-origin' });
  location.replace('index.html');
});

/* ---------- Cartões de alunos ---------- */
const chips = $('#chips');
chips.innerHTML = ['Todas', ...SKILLS].map(d => `<button type="button" class="chip" aria-pressed="${d === dif}">${d}</button>`).join('');
chips.addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b) return;
  dif = b.textContent;
  chips.querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', x === b));
  renderAlunos();
});
$('#busca').addEventListener('input', e => { q = norm(e.target.value.trim()); renderAlunos(); });
$('#form-busca').addEventListener('submit', e => e.preventDefault());

async function carregarAlunos() {
  const r = await api('/api/alunos');
  if (!r.ok) { $('#status').textContent = 'Erro: não foi possível carregar os alunos.'; return; }
  alunos = await r.json();
  renderAlunos();
  const op = alunos.map(a => `<option value="${a.id}">${esc(a.nome)} (${esc(a.nivel)})</option>`).join('');
  if ($('#alunoSel')) $('#alunoSel').innerHTML = op;
  $('#f-aluno').innerHTML = '<option value="">Todos os alunos</option>' + op;
}
function renderAlunos() {
  const r = alunos.filter(a => (dif === 'Todas' || a.dificuldade === dif) && norm(a.nome).includes(q));
  $('#lista').innerHTML = r.map(cartao).join('');
  $('#status').textContent = r.length ? `${r.length} aluno(s) encontrado(s).` : 'Nenhum aluno encontrado. Limpe a busca ou escolha outra dificuldade.';
}
function cartao(a) {
  const topo = `<div class="card-top"><h3>${esc(a.nome)}</h3><span class="badge b-nivel">Nível ${esc(a.nivel)}</span></div>`;
  if (a.mediaAtual == null) return `<li><article class="card">${topo}<p>Ainda não há notas lançadas.</p></article></li>`;
  const d = a.mediaAnterior == null ? null : +(a.mediaAtual - a.mediaAnterior).toFixed(1);
  const [cls, ico, txt] = d == null ? ['b-nivel', '●', 'Primeira medição'] : d > 0 ? ['b-evol', '▲', `Subiu ${d} pontos`] : d < 0 ? ['b-meta', '▼', `Caiu ${-d} pontos`] : ['b-nivel', '●', 'Sem variação'];
  const abaixo = a.mediaAtual < a.meta;
  return `<li><article class="card">${topo}
    <p>Maior dificuldade em ${fmtMes(a.mes)}: <strong>${esc(a.dificuldade)}</strong></p>
    <progress max="100" value="${a.mediaAtual}" aria-label="Média de ${esc(a.dificuldade)} de ${esc(a.nome)}">${a.mediaAtual}%</progress>
    <p>Média ${a.mediaAtual}%${a.mediaAnterior != null ? `, antes ${a.mediaAnterior}%` : ''}. Meta do nível: ${a.meta}%.</p>
    <p class="tags"><span class="badge ${cls}"><span aria-hidden="true">${ico}</span> ${txt}</span>
    <span class="badge ${abaixo ? 'b-meta' : 'b-evol'}"><span aria-hidden="true">${abaixo ? '⚠' : '✔'}</span> ${abaixo ? 'Abaixo da meta' : 'Na meta'}</span></p></article></li>`;
}

/* ---------- Dashboard ---------- */
function montarFiltros() {
  $('#f-nivel').innerHTML = '<option value="">Todos os níveis</option>' + ['A1', 'A2', 'B1', 'B2', 'C1', 'C2'].map(n => `<option>${n}</option>`).join('');
  $('#f-comp').innerHTML = '<option value="">Todas as habilidades</option>' + SKILLS.map((s, i) => `<option value="${i + 1}">${s}</option>`).join('');
}
$('#form-dash').addEventListener('change', carregarEvolucao);
$('#form-dash').addEventListener('submit', e => e.preventDefault());

async function carregarEvolucao() {
  const p = new URLSearchParams();
  [['alunoId', '#f-aluno'], ['nivel', '#f-nivel'], ['competenciaId', '#f-comp'], ['tipo', '#f-tipo'], ['de', '#f-de'], ['ate', '#f-ate']]
    .forEach(([k, s]) => { const v = $(s).value; if (v) p.set(k, v); });
  const r = await api('/api/evolucao?' + p);
  if (!r.ok) { $('#resumo').textContent = 'Erro: não foi possível carregar o dashboard.'; return; }
  evol = await r.json();
  desenhar();
}
document.addEventListener('tema', () => { if (user) desenhar(); });   // tema ou modo de cor mudou

function desenhar() {
  const css = v => getComputedStyle(root).getPropertyValue(v).trim();
  const meses = [...new Set(evol.map(e => e.mes))].sort();
  const habs = [...new Set(evol.map(e => e.competencia))].sort((a, b) => SKILLS.indexOf(a) - SKILLS.indexOf(b));
  grafico?.destroy(); grafico = null;
  if (!meses.length) {
    $('#resumo').textContent = 'Nenhuma nota encontrada para os filtros escolhidos. Ajuste os filtros.';
    $('#tabela').innerHTML = '';
    return;
  }

  const pal = PAL[root.dataset.dalt] || PAL.padrao;
  const dados = (h, m) => evol.find(e => e.mes === m && e.competencia === h);
  const ds = habs.map(h => {
    const k = SKILLS.indexOf(h);
    return { label: h, data: meses.map(m => dados(h, m)?.mediaPct ?? null), borderColor: pal[k], backgroundColor: pal[k],
             borderDash: TRACO[k], pointStyle: MARCA[k], pointRadius: 5, borderWidth: 2.5, tension: .25, spanGaps: true };
  });
  ds.push({ label: 'Meta do nível (média)', borderColor: css('--meta'), backgroundColor: css('--meta'), borderDash: [10, 5], pointRadius: 0, pointStyle: false, borderWidth: 3,
            data: meses.map(m => { const x = evol.filter(e => e.mes === m); return x.length ? +(x.reduce((s, e) => s + e.metaPct, 0) / x.length).toFixed(1) : null; }) });

  if (window.Chart) {
    const ink = css('--ink'), grade = 'rgba(128,128,128,.35)';
    Chart.defaults.font.family = '"Atkinson Hyperlegible",Verdana,sans-serif';
    Chart.defaults.font.size = 14;
    grafico = new Chart($('#grafico'), {
      type: 'line', data: { labels: meses.map(fmtMes), datasets: ds },
      options: {
        responsive: true, maintainAspectRatio: false, animation: reduz ? false : { duration: 400 },
        scales: {
          y: { min: 0, max: 100, title: { display: true, text: 'Média (%)', color: ink }, ticks: { color: ink }, grid: { color: grade } },
          x: { ticks: { color: ink }, grid: { color: grade } }
        },
        plugins: { legend: { labels: { color: ink, usePointStyle: true, boxWidth: 12 } } }
      }
    });
  }
  $('#grafico').setAttribute('aria-label', `Gráfico de linhas com a média de ${habs.join(', ')} de ${fmtMes(meses[0])} a ${fmtMes(meses.at(-1))}, comparada com a meta do nível. Os mesmos dados estão na tabela abaixo.`);

  const ult = evol.filter(e => e.mes === meses.at(-1));
  const abaixo = ult.filter(e => e.mediaPct < e.metaPct).map(e => e.competencia);
  const menor = ult.reduce((a, b) => (b.mediaPct - b.metaPct < a.mediaPct - a.metaPct ? b : a));
  $('#resumo').textContent = `Em ${fmtMes(meses.at(-1))}: ${abaixo.length ? `abaixo da meta em ${abaixo.join(', ')}` : 'todas as habilidades estão na meta ou acima'}. `
    + `Menor margem sobre a meta: ${menor.competencia}, ${menor.mediaPct}% para meta de ${menor.metaPct}%.`
    + (window.Chart ? '' : ' O gráfico não carregou; use a tabela.');

  $('#tabela').innerHTML = `<caption>Média por habilidade e mês, com a meta do nível</caption>
    <thead><tr><th scope="col">Habilidade</th>${meses.map(m => `<th scope="col">${fmtMes(m)}</th>`).join('')}</tr></thead>
    <tbody>${habs.map(h => `<tr><th scope="row">${esc(h)}</th>${meses.map(m => {
      const e = dados(h, m);
      return `<td>${e ? `${e.mediaPct}% (meta ${e.metaPct}%) ${e.mediaPct < e.metaPct ? '⚠ abaixo' : '✔ na meta'}` : '—'}</td>`;
    }).join('')}</tr>`).join('')}</tbody>`;
}

/* ---------- Lançar notas (Professor) ---------- */
async function carregarAvals() {
  if (user.papel !== 'Professor') return;
  const r = await api('/api/avaliacoes');
  if (!r.ok) return;
  avals = await r.json();
  $('#avalSel').innerHTML = avals.map(a => `<option value="${a.id}">${esc(a.tipo)}: ${esc(a.titulo)} (${esc(a.nivel)}, ${esc(a.competencia)}, máx. ${a.notaMaxima})</option>`).join('');
  ajustarMax();
}
function ajustarMax() { const a = avals.find(x => x.id === +$('#avalSel').value); if (a) $('#nota').max = a.notaMaxima; }
$('#avalSel').addEventListener('change', ajustarMax);
$('#form-registro').addEventListener('submit', async e => {
  e.preventDefault();
  const f = e.target.elements, st = $('#status-registro');
  st.className = ''; st.textContent = 'Salvando…';
  const r = await api('/api/resultados', { method: 'POST', body: JSON.stringify({
    alunoId: +f.aluno.value, avaliacaoId: +f.aval.value, nota: f.nota.valueAsNumber, observacao: f.observacao.value.trim() || null }) }).catch(() => null);
  if (!r) { st.className = 'erro'; st.textContent = 'Erro: sem conexão com o servidor.'; return; }
  if (r.ok) {
    st.className = 'ok'; st.textContent = 'Sucesso: nota registrada.';
    f.nota.value = ''; f.observacao.value = '';
    await carregarAlunos(); await carregarEvolucao();
  } else { st.className = 'erro'; st.textContent = 'Erro: ' + await erroDe(r); }
});

/* ---------- Carrossel (sem rotação automática, por acessibilidade) ---------- */
const slides = $$('.slide'), cont = $('#cont'); let idx = 0;
function mostrar(n) {
  idx = (n + slides.length) % slides.length;
  slides.forEach((s, k) => s.hidden = k !== idx);
  cont.textContent = `Destaque ${idx + 1} de ${slides.length}`;
}
$('#ant').addEventListener('click', () => mostrar(idx - 1));
$('#prox').addEventListener('click', () => mostrar(idx + 1));
$('#carrossel').addEventListener('keydown', e => { if (e.key === 'ArrowLeft') mostrar(idx - 1); if (e.key === 'ArrowRight') mostrar(idx + 1); });
mostrar(0);

/* ---------- Formulário de contato ---------- */
const cf = $('#contato-form'), cok = $('#ok');
const regras = { nome: v => v.trim().length >= 3, email: v => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v), mensagem: v => v.trim().length >= 10 };
cf.addEventListener('submit', async e => {
  e.preventDefault(); cok.textContent = ''; cok.className = '';
  let primeiro = null;
  for (const id in regras) {
    const el = cf.elements[id], er = $('#erro-' + id), ruim = !regras[id](el.value);
    el.setAttribute('aria-invalid', ruim); er.hidden = !ruim;
    ruim ? el.setAttribute('aria-describedby', 'erro-' + id) : el.removeAttribute('aria-describedby');
    if (ruim && !primeiro) primeiro = el;
  }
  if (primeiro) return primeiro.focus();
  const r = await api('/api/contatos', { method: 'POST', body: JSON.stringify({ nome: cf.elements.nome.value, email: cf.elements.email.value, mensagem: cf.elements.mensagem.value }) }).catch(() => null);
  if (r?.ok) { cok.className = 'ok'; cok.textContent = 'Mensagem enviada. Responderei em até 2 dias úteis.'; cf.reset(); }
  else { cok.className = 'erro'; cok.textContent = 'Erro: ' + (r ? await erroDe(r) : 'sem conexão com o servidor.'); }
});

init();