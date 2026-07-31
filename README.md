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
