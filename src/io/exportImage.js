// Graphic export: SVG, PNG, and PDF via the browser's own print engine
// (which keeps the PDF vector — no third-party PDF library needed).

import { downloadBlob, downloadText, slugify, escapeXml } from '../util.js';
import { SHEET } from '../model/types.js';
import { diagramToSvgString, EXPORT_CSS } from '../ui/render.js';
import { diagramTree } from '../model/model.js';

export function exportSvg(model, diagram) {
  const name = `${slugify(model.title)}-${slugify(diagram.node)}.svg`;
  downloadText(diagramToSvgString(model, diagram), name, 'image/svg+xml');
  return name;
}

export async function exportPng(model, diagram, scale = 2) {
  const svgText = diagramToSvgString(model, diagram);
  const blob = await rasterize(svgText, SHEET.w * scale, SHEET.h * scale);
  const name = `${slugify(model.title)}-${slugify(diagram.node)}.png`;
  downloadBlob(blob, name);
  return name;
}

function rasterize(svgText, w, h) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(new Blob([svgText], { type: 'image/svg+xml;charset=utf-8' }));
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = w; canvas.height = h;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(img, 0, 0, w, h);
      URL.revokeObjectURL(url);
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Canvas produced no image.'))), 'image/png');
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('The diagram could not be rasterised.')); };
    img.src = url;
  });
}

/**
 * Open a print window holding one landscape page per diagram. "Save as PDF"
 * in the print dialog produces a vector, multi-page IDEF0 kit.
 */
export function printDiagrams(model, diagrams) {
  const pages = diagrams.map((d) => {
    const body = diagramToSvgString(model, d).replace(/^<\?xml[^>]*\?>\s*/, '').replace(/^<!--[\s\S]*?-->\s*/, '');
    return `<section class="page">${body}</section>`;
  }).join('\n');

  const html = `<!doctype html><html><head><meta charset="utf-8">
<title>${escapeXml(model.title)}</title>
<style>
@page { size: ${SHEET.w}px ${SHEET.h}px; margin: 0; }
html,body{margin:0;padding:0;background:#fff}
.page{width:${SHEET.w}px;height:${SHEET.h}px;page-break-after:always;overflow:hidden}
.page:last-child{page-break-after:auto}
svg{display:block;width:${SHEET.w}px;height:${SHEET.h}px}
${EXPORT_CSS}
</style></head><body>${pages}
<script>window.addEventListener('load',()=>{setTimeout(()=>window.print(),250)})<\/script>
</body></html>`;

  const w = window.open('', '_blank');
  if (!w) throw new Error('The browser blocked the print window. Allow pop-ups for this page and try again.');
  w.document.open();
  w.document.write(html);
  w.document.close();
}

export function printAll(model) {
  printDiagrams(model, diagramTree(model).map((n) => n.diagram));
}
