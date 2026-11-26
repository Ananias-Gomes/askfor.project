/* Carregar no <head>, sem defer: aplica tema e modo de cor antes da primeira pintura (sem flash). */
(() => {
  const R = document.documentElement;
  const ler = k => { try { return localStorage.getItem(k); } catch (_) { return null; } };
  const gravar = (k, v) => { try { localStorage.setItem(k, v); } catch (_) {} };
  const DALT = ['padrao', 'protanopia', 'deuteranopia', 'tritanopia'];

  const t = ler('tema');
  R.dataset.tema = ['claro', 'escuro'].includes(t) ? t : (matchMedia('(prefers-color-scheme:dark)').matches ? 'escuro' : 'claro');
  R.dataset.dalt = DALT.includes(ler('dalt')) ? ler('dalt') : 'padrao';

  addEventListener('DOMContentLoaded', () => {
    const btn = document.getElementById('tema'), sel = document.getElementById('dalt');
    const avisar = () => document.dispatchEvent(new Event('tema'));   // o gráfico se redesenha com as novas cores
    if (btn) {
      btn.setAttribute('aria-pressed', R.dataset.tema === 'escuro');
      btn.addEventListener('click', () => {
        const escuro = R.dataset.tema !== 'escuro';
        R.dataset.tema = escuro ? 'escuro' : 'claro';
        btn.setAttribute('aria-pressed', escuro);
        gravar('tema', R.dataset.tema);
        avisar();
      });
    }
    if (sel) {
      sel.value = R.dataset.dalt;
      sel.addEventListener('change', () => { R.dataset.dalt = sel.value; gravar('dalt', sel.value); avisar(); });
    }
  });
})();