#!/usr/bin/env bash
# Playrate Tracker · genera el arbol completo. Idempotente.
set -euo pipefail

mkdir -p src .github/workflows

cat > 'package.json' <<'PLAYRATE_EOF'
{
  "name": "playrate-tracker",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": {
    "probe": "node src/probe.js",
    "track": "node src/track.js"
  },
  "dependencies": {
    "@supabase/supabase-js": "^2.45.0"
  }
}
PLAYRATE_EOF
echo "  escrito package.json"

cat > '.gitignore' <<'PLAYRATE_EOF'
node_modules
.env
.DS_Store
probe-output.json
PLAYRATE_EOF
echo "  escrito .gitignore"

cat > '.env.example' <<'PLAYRATE_EOF'
SUPABASE_URL=https://tuproyecto.supabase.co
SUPABASE_SERVICE_KEY=pega_aqui_la_service_role
SUPABASE_BUCKET=shots
PLAYRATE_EOF
echo "  escrito .env.example"

cat > 'schema.sql' <<'PLAYRATE_EOF'
-- ── Catálogo de categorías (géneros) ──
create table if not exists sorts (
  sort_id      text primary key,
  display_name text not null,
  first_seen   date not null default current_date,
  last_seen    date not null default current_date
);

-- ── Cada experiencia que vemos alguna vez ──
create table if not exists experiences (
  universe_id   bigint primary key,
  root_place_id bigint,
  name          text,
  creator_name  text,
  creator_id    bigint,
  created_at    timestamptz,
  first_seen    date not null default current_date,
  last_seen     date not null default current_date
);

-- ── Foto diaria de métricas. Una fila por juego por día. ──
create table if not exists snapshots (
  id           bigserial primary key,
  universe_id  bigint not null references experiences(universe_id) on delete cascade,
  captured_on  date   not null default current_date,
  visits       bigint,
  playing      integer,
  favorites    bigint,
  max_players  integer,
  game_updated timestamptz,
  unique (universe_id, captured_on)
);
create index if not exists snapshots_day  on snapshots(captured_on);
create index if not exists snapshots_univ on snapshots(universe_id);

-- ── En qué categoría y en qué posición apareció cada juego ──
create table if not exists placements (
  id          bigserial primary key,
  universe_id bigint not null references experiences(universe_id) on delete cascade,
  sort_id     text   not null,
  rank        integer not null,
  captured_on date   not null default current_date,
  unique (universe_id, sort_id, captured_on)
);
create index if not exists placements_sort on placements(sort_id, captured_on);

-- ── EL FOSO: cada versión distinta de cada imagen ──
-- La clave única sobre sha256 hace que solo se guarde cuando la imagen CAMBIÓ.
create table if not exists images (
  id            bigserial primary key,
  universe_id   bigint not null references experiences(universe_id) on delete cascade,
  kind          text   not null check (kind in ('thumbnail','icon')),
  sha256        text   not null,
  storage_path  text   not null,
  bytes         integer,
  first_seen_on date   not null default current_date,
  last_seen_on  date   not null default current_date,
  unique (universe_id, kind, sha256)
);
create index if not exists images_univ on images(universe_id, kind);

-- ── Registro de cada corrida, para saber si el cron se cayó ──
create table if not exists runs (
  id             bigserial primary key,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  sorts_seen     integer,
  universes_seen integer,
  images_new     integer,
  errors         integer,
  notes          text
);

-- ── Vista de crecimiento a 7 días: esto es lo que vende ──
create or replace view movers_7d as
with latest as (
  select universe_id, max(captured_on) as d from snapshots group by universe_id
),
now_ as (
  select s.universe_id, s.visits, s.playing, s.captured_on
  from snapshots s join latest l
    on l.universe_id = s.universe_id and l.d = s.captured_on
),
then_ as (
  select distinct on (s.universe_id)
         s.universe_id, s.visits as visits_then, s.captured_on as then_on
  from snapshots s join latest l on l.universe_id = s.universe_id
  where s.captured_on <= l.d - 7
  order by s.universe_id, s.captured_on desc
)
select e.universe_id,
       e.name,
       n.visits,
       n.playing,
       t.visits_then,
       n.visits - t.visits_then as visit_delta,
       round(100.0 * (n.visits - t.visits_then) / nullif(t.visits_then,0), 2) as pct_7d,
       t.then_on,
       n.captured_on
from now_ n
join then_ t using (universe_id)
join experiences e using (universe_id)
where t.visits_then > 0;
PLAYRATE_EOF
echo "  escrito schema.sql"

cat > 'src/roblox.js' <<'PLAYRATE_EOF'
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
    .filter(s => s.sortId);
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
PLAYRATE_EOF
echo "  escrito src/roblox.js"

cat > 'src/probe.js' <<'PLAYRATE_EOF'
import { writeFileSync } from 'node:fs';
import { newSession, getSorts, getSortContent, getGameDetails, getThumbUrls } from './roblox.js';

const session = newSession();
console.log('sesión:', session, '\n');

const report = {};

try {
  const sorts = await getSorts(session);
  report.sorts = sorts;
  console.log(`✅ ${sorts.length} categorías encontradas:`);
  sorts.forEach(s => console.log(`   · ${s.displayName}  [${s.sortId}]`));

  if (!sorts.length) throw new Error('Cero categorías. La forma de la respuesta cambió: mira probe-output.json');

  const test = sorts[0];
  const ids = await getSortContent(session, test.sortId);
  report.sampleSort = { ...test, count: ids.length, ids: ids.slice(0, 10) };
  console.log(`\n✅ "${test.displayName}" devolvió ${ids.length} juegos`);
  console.log('   (si dice 100, ese es el techo por categoría, es normal)');

  if (ids.length) {
    const details = await getGameDetails(ids.slice(0, 3));
    report.sampleDetails = details;
    console.log('\n✅ Detalles de ejemplo:');
    details.forEach(g => console.log(`   · ${g.name} — ${g.visits?.toLocaleString()} visitas, ${g.playing} jugando`));

    const thumbs = await getThumbUrls(ids.slice(0, 3));
    report.sampleThumbs = Object.fromEntries(thumbs);
    console.log(`\n✅ ${thumbs.size} miniaturas resueltas`);
  }

  console.log('\n🎉 Todo respondiendo. Puedes correr el rastreador.');
} catch (err) {
  console.error('\n❌ Falló:', err.message);
  console.error('Revisa probe-output.json para ver la respuesta cruda y ajustar roblox.js');
  process.exitCode = 1;
} finally {
  writeFileSync('probe-output.json', JSON.stringify(report, null, 2));
  console.log('\nGuardado en probe-output.json');
}
PLAYRATE_EOF
echo "  escrito src/probe.js"

cat > 'src/db.js' <<'PLAYRATE_EOF'
import { createClient } from '@supabase/supabase-js';

const { SUPABASE_URL, SUPABASE_SERVICE_KEY } = process.env;
if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
  throw new Error('Faltan SUPABASE_URL o SUPABASE_SERVICE_KEY. Revisa tu .env');
}

export const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false },
});

export const BUCKET = process.env.SUPABASE_BUCKET ?? 'shots';
export const today = () => new Date().toISOString().slice(0, 10);
PLAYRATE_EOF
echo "  escrito src/db.js"

cat > 'src/track.js' <<'PLAYRATE_EOF'
import { createHash } from 'node:crypto';
import { db, BUCKET, today } from './db.js';
import {
  newSession, getSorts, getSortContent, getGameDetails,
  getThumbUrls, getIconUrls, fetchImageBytes, chunk, sleep,
} from './roblox.js';

const DAY = today();
const PAUSE = 700;          // ms entre llamadas. No lo bajes de 500.
const stats = { sorts: 0, universes: 0, imagesNew: 0, errors: 0 };

const { data: run } = await db.from('runs').insert({ notes: `día ${DAY}` }).select().single();
console.log(`▶ corrida #${run?.id} · ${DAY}\n`);

// ─────────────────────────────────────────────
// 1. Categorías
// ─────────────────────────────────────────────
const session = newSession();
const sorts = await getSorts(session);
stats.sorts = sorts.length;
console.log(`1/5 · ${sorts.length} categorías`);

await db.from('sorts').upsert(
  sorts.map(s => ({ sort_id: s.sortId, display_name: s.displayName, last_seen: DAY })),
  { onConflict: 'sort_id' },
);

// ─────────────────────────────────────────────
// 2. Contenido de cada categoría
// ─────────────────────────────────────────────
const placements = [];
const seen = new Set();

for (const s of sorts) {
  try {
    const ids = await getSortContent(session, s.sortId);
    ids.forEach((universeId, i) => {
      seen.add(universeId);
      placements.push({ universe_id: universeId, sort_id: s.sortId, rank: i + 1, captured_on: DAY });
    });
    console.log(`      ${s.displayName}: ${ids.length}`);
  } catch (err) {
    stats.errors++;
    console.error(`      ✗ ${s.displayName}: ${err.message}`);
  }
  await sleep(PAUSE);
}

const universeIds = [...seen];
stats.universes = universeIds.length;
console.log(`\n2/5 · ${universeIds.length} juegos únicos`);

if (!universeIds.length) {
  await db.from('runs').update({ finished_at: new Date(), ...snake(stats), notes: 'cero juegos, aborté' }).eq('id', run.id);
  throw new Error('Cero juegos. Corre `npm run probe` para ver qué cambió.');
}

// ─────────────────────────────────────────────
// 3. Métricas
// ─────────────────────────────────────────────
console.log('3/5 · métricas');
const detailBatches = chunk(universeIds, 100);

for (const [i, batch] of detailBatches.entries()) {
  try {
    const games = await getGameDetails(batch);

    await db.from('experiences').upsert(
      games.map(g => ({
        universe_id: g.id,
        root_place_id: g.rootPlaceId ?? null,
        name: g.name ?? null,
        creator_name: g.creator?.name ?? null,
        creator_id: g.creator?.id ?? null,
        created_at: g.created ?? null,
        last_seen: DAY,
      })),
      { onConflict: 'universe_id' },
    );

    await db.from('snapshots').upsert(
      games.map(g => ({
        universe_id: g.id,
        captured_on: DAY,
        visits: g.visits ?? null,
        playing: g.playing ?? null,
        favorites: g.favoritedCount ?? null,
        max_players: g.maxPlayers ?? null,
        game_updated: g.updated ?? null,
      })),
      { onConflict: 'universe_id,captured_on' },
    );

    console.log(`      lote ${i + 1}/${detailBatches.length}`);
  } catch (err) {
    stats.errors++;
    console.error(`      ✗ lote ${i + 1}: ${err.message}`);
  }
  await sleep(PAUSE);
}

// Los placements van después de experiences por la llave foránea
for (const batch of chunk(placements, 500)) {
  await db.from('placements').upsert(batch, { onConflict: 'universe_id,sort_id,captured_on' });
}

// ─────────────────────────────────────────────
// 4. Imágenes: aquí está el negocio
// ─────────────────────────────────────────────
console.log('4/5 · imágenes');

async function keepImage(universeId, kind, url) {
  const bytes = await fetchImageBytes(url);
  const sha = createHash('sha256').update(bytes).digest('hex');

  // ¿Ya tenemos esta versión exacta? Entonces solo marcamos que sigue vigente.
  const { data: known } = await db
    .from('images')
    .select('id')
    .eq('universe_id', universeId).eq('kind', kind).eq('sha256', sha)
    .maybeSingle();

  if (known) {
    await db.from('images').update({ last_seen_on: DAY }).eq('id', known.id);
    return false;
  }

  // Versión nueva. Se guarda sin tocar las anteriores.
  const path = `${kind}/${universeId}/${sha.slice(0, 16)}.png`;
  const { error: upErr } = await db.storage.from(BUCKET)
    .upload(path, bytes, { contentType: 'image/png', upsert: true });
  if (upErr) throw new Error(`storage: ${upErr.message}`);

  await db.from('images').insert({
    universe_id: universeId, kind, sha256: sha,
    storage_path: path, bytes: bytes.length,
    first_seen_on: DAY, last_seen_on: DAY,
  });
  return true;
}

for (const [i, batch] of chunk(universeIds, 100).entries()) {
  try {
    const [thumbs, icons] = await Promise.all([getThumbUrls(batch), getIconUrls(batch)]);

    for (const universeId of batch) {
      for (const [kind, map] of [['thumbnail', thumbs], ['icon', icons]]) {
        const url = map.get(universeId);
        if (!url) continue;
        try {
          if (await keepImage(universeId, kind, url)) stats.imagesNew++;
        } catch (err) {
          stats.errors++;
          console.error(`      ✗ ${kind} ${universeId}: ${err.message}`);
        }
        await sleep(120);
      }
    }
    console.log(`      lote ${i + 1} · ${stats.imagesNew} imágenes nuevas hasta ahora`);
  } catch (err) {
    stats.errors++;
    console.error(`      ✗ lote de imágenes ${i + 1}: ${err.message}`);
  }
}

// ─────────────────────────────────────────────
// 5. Cierre
// ─────────────────────────────────────────────
function snake(s) {
  return { sorts_seen: s.sorts, universes_seen: s.universes, images_new: s.imagesNew, errors: s.errors };
}

await db.from('runs').update({ finished_at: new Date(), ...snake(stats) }).eq('id', run.id);

console.log(`\n5/5 · listo`);
console.log(`      ${stats.universes} juegos · ${stats.imagesNew} imágenes nuevas · ${stats.errors} errores`);

if (stats.errors > stats.universes * 0.25) {
  console.error('Más del 25% falló. Algo se rompió, revísalo.');
  process.exitCode = 1;
}
PLAYRATE_EOF
echo "  escrito src/track.js"

cat > '.github/workflows/track.yml' <<'PLAYRATE_EOF'
name: rastreador diario

on:
  schedule:
    # 11:00 UTC = 07:00 en Chile. Cron siempre va en UTC.
    - cron: '0 11 * * *'
  workflow_dispatch:        # botón para correrlo a mano

jobs:
  track:
    runs-on: ubuntu-latest
    timeout-minutes: 50
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: npm
      - run: npm ci
      - run: npm run track
        env:
          SUPABASE_URL:         ${{ secrets.SUPABASE_URL }}
          SUPABASE_SERVICE_KEY: ${{ secrets.SUPABASE_SERVICE_KEY }}
          SUPABASE_BUCKET:      shots
PLAYRATE_EOF
echo "  escrito .github/workflows/track.yml"

cat > 'README.md' <<'PLAYRATE_EOF'
// Playrate Tracker

Rastreador diario de las categorías públicas de Roblox. Guarda métricas por día
y, sobre todo, guarda cada versión distinta de cada miniatura e icono.

Las URLs del CDN de Roblox caducan y las miniaturas reemplazadas desaparecen
para siempre. Este repo es el único lugar donde queda ese historial.

## Correr

    npm install
    cp .env.example .env    # rellena tus valores
    npm run probe           # verifica que la API responde. SIEMPRE primero.
    npm run track           # corrida completa

## Límites conocidos

- explore-api no está documentada. Puede cambiar sin aviso: para eso está el probe.
- Máximo 100 experiencias por categoría, sin paginación.
- Con 15 a 20 categorías quedan entre 1.000 y 1.500 juegos únicos por día.

## Automatización

GitHub Actions corre `npm run track` a las 11:00 UTC. Necesita los secretos
SUPABASE_URL y SUPABASE_SERVICE_KEY. Los cron de GitHub se pausan a los 60 días
sin actividad en el repo: haz un commit de vez en cuando.
PLAYRATE_EOF
echo "  escrito README.md"

[ -f .env ] || cp .env.example .env
echo ""
echo "Listo. 10 archivos."
echo "Ahora: 1) rellena .env  2) npm install  3) npm run probe"
