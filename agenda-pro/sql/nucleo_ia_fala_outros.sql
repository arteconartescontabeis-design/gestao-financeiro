-- Núcleo do portal (projeto fbxelwhdiisfmnwrerbl) · aplicado em 25/10/2026
-- App "outros" no Consumo de IA: guarda a diferença entre as Métricas da Azure (recurso artecon-voz) e o que os apps lançam
-- (testes e usos não lançados; o Corretor de Vídeos do Radar, CHAVE 2, só transcreve e não entra na voz). Só acrescenta.
insert into core.ia_fala_apps (app, nome, tipo, descricao)
values ('outros', 'Outros usos do recurso artecon-voz', 'voz',
        'Diferença entre as Métricas da Azure e os lançamentos dos apps (ex.: Corretor de Vídeos do Radar, CHAVE 2; testes)')
on conflict (app) do nothing;

-- Ajustes lançados em 25/10/2026 (dados, não estrutura), para o total de outubro bater com a Azure
-- (Synthesized Characters, soma 01–25/10 = 479.290):
--   estudo +122.986: a Azure cobra também as marcações SSML (pausas <break>, siglas <say-as>); o Estudo enviou 426.188
--   outros  +46.102: pico de ~27 mil em 09–10/10 (provável Projeto Criança acima dos 7 mil estimados) e ~10 mil em ~20/10
