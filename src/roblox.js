import { randomUUID } from 'node:crypto';

// Si Roblox te bloquea por IP, monta tu propio proxy y cambia esto.
// roproxy.com es de un tercero que ve todo tu tráfico: úsalo solo para probar.
const HOST = process.env.ROBLOX_HOST ?? 'roblox.com';
const api  = (sub) => `https://${sub}.${HOST}`;

const UA = 'playrate-tracker/1.0 (research; contacto: tu-email@ejemplo.com)';

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/**
 * fetch con reintentos y espera exponencial.
 * 429 = te pasaste de la mano. 5xx = problema de ellos. Ambos se reintentan.
 */
async function grab(url, opts = {}, tries = 5) {
  for (let i = 0; i < tries; i++) {
    try {
      const res = await fetch(url, {
        ...opts,
        headers: { 'User-Agent': UA, 'Accept': 'application/json', ...(opts.headers ?? {}) },
        signal: AbortSignal.timeout(25_000),
      });

      if (res.status === 429 || res.status >= 500) {
        const wait = Math.min(2 ** i * 1200, 30_000) + Math.random() * 800;
        console.warn(`  ${res.status} en ${url.slice(0, 70)} · espero ${Math.round(wait)}ms`);
        await sleep(wait);
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status} en ${url}`);
      return res;
    } catch (err) {
      if (i === tries - 1) throw err;
      const wait = Math.min(2 ** i * 1200, 30_000);
      console.warn(`  falló (${err.message}) · reintento en ${wait}ms`);
      await sleep(wait);
    }
  }
}

const grabJson = async (url, opts) => (await grab(url, opts)).json();

/** Trocea un array en pedazos de tamaño n. La API acepta 100 ids por llamada. */
export const chunk = (arr, n) =>
  Array.from({ length: Math.ceil(arr.length / n) }, (_, i) => arr.slice(i * n, i * n + n));

/**
 * Extrae ids de universo de una respuesta de forma desconocida.
 * La API de explore no está documentada y su forma cambia, así que buscamos
 * recursivamente cualquier objeto que tenga universeId. Feo pero sobrevive.
 */
export function digUniverseIds(node, out = []) {
  if (Array.isArray(node)) { node.forEach(n => digUniverseIds(n, out)); return out; }
  if (node && typeof node === 'object') {
    const id = node.universeId ?? node.universeID ?? node.UniverseId;
    if (id != null && Number.isFinite(Number(id))) out.push(Number(id));
    Object.values(node).forEach(v => digUniverseIds(v, out));
  }
  return out;
}

/** Una sesión por corrida. La API la exige. */
export const newSession = () => randomUUID();

/** Lista las categorías (géneros) de la página Charts. */
export async function getSorts(sessionId) {
  const url = `${api('apis')}/explore-api/v1/get-sorts?sessionId=${sessionId}`;
  const raw = await grabJson(url);
  const list = raw.sorts ?? raw.data ?? [];
  return list
    .map(s => ({
      sortId: s.sortId ?? s.id ?? s.topicId,
      displayName: s.sortDisplayName ?? s.displayName ?? s.topic ?? 'sin nombre',
    }))
    .filter(s => s.sortId && s.displayName?.trim());
}

/** Contenido de una categoría. Máximo 100, sin paginación. */
export async function getSortContent(sessionId, sortId) {
  const url = `${api('apis')}/explore-api/v1/get-sort-content`
            + `?sessionId=${sessionId}&sortId=${encodeURIComponent(sortId)}`;
  const raw = await grabJson(url);
  return digUniverseIds(raw);
}

/** Métricas de hasta 100 universos por llamada. */
export async function getGameDetails(universeIds) {
  const url = `${api('games')}/v1/games?universeIds=${universeIds.join(',')}`;
  const raw = await grabJson(url);
  return raw.data ?? [];
}

/** URLs de miniaturas (16:9). */
export async function getThumbUrls(universeIds) {
  const url = `${api('thumbnails')}/v1/games/multiget/thumbnails`
            + `?universeIds=${universeIds.join(',')}&size=768x432&format=Png&isCircular=false`;
  const raw = await grabJson(url);
  const map = new Map();
  for (const row of raw.data ?? []) {
    const first = (row.thumbnails ?? []).find(t => t.state === 'Completed' && t.imageUrl);
    if (first) map.set(Number(row.universeId), first.imageUrl);
  }
  return map;
}

/** URLs de iconos (cuadrados). */
export async function getIconUrls(universeIds) {
  const url = `${api('thumbnails')}/v1/games/icons`
            + `?universeIds=${universeIds.join(',')}&size=512x512&format=Png&isCircular=false`;
  const raw = await grabJson(url);
  const map = new Map();
  for (const row of raw.data ?? []) {
    if (row.state === 'Completed' && row.imageUrl) map.set(Number(row.targetId ?? row.universeId), row.imageUrl);
  }
  return map;
}

/** Baja los bytes de una imagen del CDN. */
export async function fetchImageBytes(url) {
  const res = await grab(url, { headers: { Accept: 'image/*' } });
  return Buffer.from(await res.arrayBuffer());
}

export { sleep };
