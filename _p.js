const {FUENTES,descargar,cuerpoDe}=require('./tools/noticias/fetch');
const {analizarNota}=require('./tools/noticias/evaluar');
(async()=>{
  const f=FUENTES.find(x=>x.nombre==='afmedios');
  const notas=await descargar(f);
  console.log('afmedios notas:', notas.length);
  const n=notas.find(x=>/motocicleta|lesionada/i.test(x.texto));
  if(!n){ console.log('no está la nota de la moto en el feed actual'); return; }
  console.log('titular:', n.texto.slice(0,90));
  const detalle=await cuerpoDe(n);
  console.log('cuerpo:', (detalle||'').slice(0,300).replace(/\s+/g,' '));
  const r=await analizarNota({...n, detalle});
  console.log('resultado:', r.nota? `${r.nota.tipo} · ${r.nota.lugar} ${r.nota.lat},${r.nota.lon} [${r.nota.precision_lugar}] rescate=${r.rescatada||false}` : 'descartada: '+r.motivo);
})();
