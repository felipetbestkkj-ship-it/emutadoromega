# Omegas Lab - organizacao e uso

Abra somente `Iniciar Omegas Lab.cmd`.

Com o ProgBase ja conectado, use **Rodar 1.000 cenarios** no painel `ENSAIO` — ou abra `Executar 1000 ensaios.cmd`. A campanha publica mil estados coerentes do modelo enquanto preserva a conexao atual ProgBase → ECU virtual. Ao final, `CAMPANHA_PROGBASE.md` mostra quais pedidos o ProgBase realmente fez em cada faixa de estados. Nenhuma acao fisica e envolvida: escritas, resets e AutoMatch experimental permanecem dentro da memoria da ECU virtual.

## Importar e repetir logs

Use **Importar logs** para selecionar varias exportacoes `.zip`, `.jsonl`, `.json`, `.log` ou `.txt`. O laboratorio procura telemetrias estruturadas, normaliza os campos e cria um replay local em `Dados\Importacoes`. Depois clique em **Loop importado**: os estados importados passam a ser publicados em ordem e voltam ao inicio automaticamente, sem interromper o ProgBase conectado. Ao parar, o arquivo `REPLAY_LOGS_PROGBASE.md` mostra o que o ProgBase realmente pediu durante o replay.

Arquivos seriais crus sem telemetria estruturada continuam uteis como evidencia de protocolo, mas nao podem virar estado de motor sem uma decodificacao especifica; o importador avisa quando nenhum ponto reproduzivel foi encontrado.

O laboratorio cria uma pasta propria em `Sessoes` para cada ensaio. Nela ficam o estado enviado a ECU virtual, o trafego serial, os eventos e o resumo do que aconteceu. A ECU fisica nunca e acessada.

Esta pasta e autossuficiente: o catalogo de respostas observadas utilizado pelo emulador fica em `Dados`. As sessoes e capturas historicas ficam locais e nao fazem parte da sincronizacao com o repositorio, para que o codigo do laboratorio permaneça leve e reproduzivel.

## Como usar a tela

1. Clique em **Ligar motor**.
2. Escolha um cenario pronto - marcha lenta, cruzeiro, aceleracao, cutoff ou janela AutoCal - ou ajuste os controles de conducao.
3. Faca a observacao desejada no ProgBase e registre um **marco** com uma frase curta.
4. Ao terminar, clique em **Abrir arquivos da sessao**. O resumo e os logs estao juntos.

Os botoes **Limpar pontos de gasolina**, **Limpar pontos de GNV** e **Reset total** do ProgBase agora recebem uma resposta funcional da ECU virtual: os buffers correspondentes sao limpos e a acao aparece no arquivo `protocol-events.jsonl` como `virtual-autocal-reset`. No reset total, a Curva K virtual volta a `1,000`. Isso vale somente para a bancada; nenhuma ECU fisica e acessada.

Para manter uma rotacao especifica durante um ensaio, marque **Fixar RPM** e arraste o controle ate o valor desejado. Enquanto estiver marcado, a RPM fica sob seu controle; pedal e carga continuam definindo o restante do comportamento. Ao escolher um cenario pronto, o modo fixo e desligado para o cenario funcionar normalmente.

## Controles acoplados

- **Coerente** (padrao): usa o padrao comportamental mais compativel e ajusta os sinais juntos.
- **Assistido**: mantem sua RPM fixada e adapta os demais sinais ao redor dela.
- **Livre**: permite estimativas para cenarios fora dos padroes observados; a tela avisa que a coerencia fica limitada.

Em **Comportamento**, escolha `Estavel` para leituras repetiveis, `Natural` para variacao parecida com a observada nos logs ou `Instavel` para testar tolerancia do ProgBase.

## Modelo comportamental

`Dados\modelo-comportamental.json` reune padroes agregados dos logs enviados: nao reproduz uma sessao, nao depende da versao do OMEGAS e nao contem a formula do AutoMatch da ECU. Ele e usado para formar telemetria de bancada mais coerente - RPM, MAP, pulsos, pressao e temperaturas passam a variar como um conjunto.

Se quiser gerar uma nova versao desse modelo a partir de novos logs, use `Sistema\treinar-modelo-comportamental.py`. O arquivo novo deve substituir somente o JSON dentro de `Dados` apos uma revisao.

## O que cada pasta significa

- `Sistema`: simulador e motor virtual.
- `Dados`: padroes comportamentais e material local necessario ao laboratorio.
- `Sessoes`: experimentos recentes, sempre separados.
- `Capturas\Historico`: material antigo preservado para consulta.
- `Legado`: scripts preservados, fora do caminho normal de uso.
