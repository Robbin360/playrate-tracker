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
