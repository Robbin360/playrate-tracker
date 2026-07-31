import { createHash } from 'node:crypto';
import { db, BUCKET, today } from './db.js';
import {
  newSession, getSorts, getSortContent, getGameDetails,
  getThumbUrls, getIconUrls, fetchImageBytes, chunk, sleep,
} from './roblox.js';

const DAY = today();
const PAUSE = 700;          // ms entre llamadas. No lo bajes de 500.
const stats = { sorts: 0, universes: 0, saved: 0, imagesNew: 0, errors: 0 };

const { data: run, error: runErr } = await db.from('runs').insert({ notes: `día ${DAY}` }).select().single();
if (runErr || !run) throw new Error(`No pude registrar la corrida: ${runErr?.message ?? 'sin datos'}`);
console.log(`▶ corrida #${run.id} · ${DAY}\n`);

// ─────────────────────────────────────────────
// 1. Categorías
// ─────────────────────────────────────────────
const session = newSession();
const sorts = await getSorts(session);
stats.sorts = sorts.length;
console.log(`1/5 · ${sorts.length} categorías`);

const { error: sortsErr } = await db.from('sorts').upsert(
  sorts.map(s => ({ sort_id: s.sortId, display_name: s.displayName, last_seen: DAY })),
  { onConflict: 'sort_id' },
);
if (sortsErr) { stats.errors++; console.error(`      ✗ guardando sorts: ${sortsErr.message}`); }

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
const detailBatches = chunk(universeIds, 50);

for (const [i, batch] of detailBatches.entries()) {
  try {
    const games = await getGameDetails(batch);

    const { error: expErr } = await db.from('experiences').upsert(
      games.map(g => ({
        universe_id: g.id,
        root_place_id: g.rootPlaceId ?? null,
        name: g.name ?? null,
        creator_name: g.creator?.name ?? null,
        creator_id: g.creator?.id ?? null,
        created_at: g.created ?? null,
        genre_l1: g.genre_l1 || null,
        genre_l2: g.genre_l2 || null,
        last_seen: DAY,
      })),
      { onConflict: 'universe_id' },
    );
    if (expErr) throw new Error(`experiences: ${expErr.message}`);

    const { error: snapErr } = await db.from('snapshots').upsert(
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
    if (snapErr) throw new Error(`snapshots: ${snapErr.message}`);

    stats.saved += games.length;
    console.log(`      lote ${i + 1}/${detailBatches.length} · ${games.length} guardados`);
  } catch (err) {
    stats.errors++;
    console.error(`      ✗ lote ${i + 1}: ${err.message}`);
  }
  await sleep(PAUSE);
}

// Los placements van después de experiences por la llave foránea
for (const batch of chunk(placements, 200)) {
  const { error: plErr } = await db.from('placements')
    .upsert(batch, { onConflict: 'universe_id,sort_id,captured_on' });
  if (plErr) { stats.errors++; console.error(`      ✗ placements: ${plErr.message}`); }
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

  const { error: insErr } = await db.from('images').insert({
    universe_id: universeId, kind, sha256: sha,
    storage_path: path, bytes: bytes.length,
    first_seen_on: DAY, last_seen_on: DAY,
  });
  if (insErr) {
    await db.storage.from(BUCKET).remove([path]);
    throw new Error(`db: ${insErr.message}`);
  }
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
console.log(`      ${stats.saved}/${stats.universes} juegos guardados · ${stats.imagesNew} imágenes nuevas · ${stats.errors} errores`);

if (stats.saved < stats.universes * 0.9) {
  console.error(`FALLO: solo ${stats.saved} de ${stats.universes} juegos llegaron a la base.`);
  process.exitCode = 1;
} else if (stats.errors > 0) {
  console.error(`Terminó con ${stats.errors} errores. Revisa el log de arriba.`);
  process.exitCode = 1;
}
