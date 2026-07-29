# GUIA INDUSTRIAL COMPLETO — AEB / LANDI RENZO OMEGAS / PROGBASE

## Protocolo, telemetria, parâmetros, mapas, AutoMatch, escrita, segurança e arquitetura de software de ponta a ponta

> Documento mestre orientado à implementação de um aplicativo industrial do zero. Ele cruza o executável ProgBase/Omegas 4.2.0.6, a DLL Landi 4.5.0.0, capturas seriais, o catálogo de 388 parâmetros, 800 requisições únicas observadas e a versão estável V4.2.2 do projeto.

> **Regra de honestidade técnica:** “completo” significa completo dentro do material comprovado. Itens não observados no fio ou cuja matemática reside no firmware são marcados como C2/C3/H1/H2; não são apresentados como fatos. Nenhum programador deve preencher lacunas com valores inventados.

## 0. Sumário executivo


O sistema deve ser implementado em camadas independentes:

```text
[USB / Serial]
      ↓
[Transporte com eco, timeout e fila]
      ↓
[Enquadramento + checksum + ACK/NAK]
      ↓
[Gerenciador de transações]
      ├── Telemetria rápida
      ├── Leitura de parâmetros
      ├── Escrita de parâmetros
      ├── Comandos operacionais
      ├── Diagnóstico
      └── Boot/flash
      ↓
[Decoders e transformação raw ↔ engenharia]
      ↓
[Estado operacional + banco + auditoria]
      ↓
[Mapa K / AutoMatch / Learning Engine]
      ↓
[UI industrial + API local + exportação]
```

O aplicativo industrial não deve misturar leitura serial, cálculo estatístico, banco e HTTP na mesma thread.
A ECU deve ter no máximo **uma transação pendente por vez**, com telemetria priorizada e escrita bloqueada por política.

## 1. Fontes, evidências e confiança

### 1.1 Artefatos analisados

```text
852a1c9d-2c2c-4a3a-8f5b-8a8700fa2790.exe
  size: 12643840
  SHA-256: 8a2d297c8c21ff3b4f7a47f7fe64593b0fec9014dd938bd91022dc0c68ac36f4
  MD5: 41c1981bcb20efbef815eb283e8ecff4
  version: {'FileVersion': '4.2.0.6', 'ProductVersion': '4.2.0.6'}

d4ee0348-13ba-4a9b-9dcc-d2a0680b73fe.dll
  size: 3289600
  SHA-256: 8c6b629cf1d69e13074ea8fd3203d48343d002a2ffc5503f20b6ce10ec564b15
  MD5: e94eaff37cafee2e850398a720d9a054
  version: {'FileVersion': '4.5.0.0', 'ProductVersion': '4.5.0.0'}
```

- Parâmetros catalogados: **388**.

- Requisições binárias únicas observadas: **800**.

- Eventos de interface catalogados: **379**.

- Módulos funcionais: **28**.

- Funções de nível superior na V4.2.2 atual: **97**.

### 1.2 Escala de confiança


| Nível | Uso |
|---|---|
| **C1** | Confirmado por captura serial e estrutura/disassembly. Pode orientar implementação. |
| **C2** | Confirmado estaticamente no binário/DFM, mas não capturado em ação isolada. Testar em bancada antes de transmitir. |
| **C3** | Observado no fio, mas a semântica final não está fechada. Preservar e registrar. |
| **H1** | Hipótese forte, coerente com nome, UI e valores. Não usar para escrita automática. |
| **H2** | Hipótese de trabalho. Apenas telemetria bruta e experimentação controlada. |

## 2. Perfil físico e serial


### 2.1 Perfis encontrados

Há **dois perfis operacionais** no material, e eles não devem ser confundidos:

| Perfil | Configuração | Evidência | Interpretação |
|---|---|---|---|
| ProgBase nativo Windows | **38400, 8N1**, sem flow control | C1 nas capturas e configuração da aplicação | Velocidade nativa observada no software original. |
| PyTools/Android testado | **9600, 8N1**, sem flow control | Declarado e testado no fluxo PyTools | O contrato `app.send_data/receive_data` não permite o script alterar baud; o adaptador/perfil do PyTools pode ser diferente. |

**Implementação industrial:** não hardcode um único baud universal. Ofereça perfis e auto-probe controlado:
1. abrir 38400;
2. enviar wake + init;
3. validar eco e ACK;
4. se falhar, fechar e testar 9600;
5. memorizar o perfil por identidade da ECU/adaptador.

Configuração comum:
- 8 bits;
- sem paridade;
- 1 stop bit;
- sem RTS/CTS;
- sem XON/XOFF;
- buffers recomendados de pelo menos 4096 bytes.

### 2.2 Timeouts e política de retry


Valores-base do ProgBase/capturas:
- espera de início de resposta: até ~1200 ms;
- timeout normal após sessão: ~200 ms;
- eco: deve chegar antes da resposta;
- retry de handshake: 3 tentativas;
- escrita: no máximo uma repetição automática e somente se **nenhum ACK válido** foi recebido;
- nunca repetir cegamente uma escrita cujo ACK se perdeu, pois a ECU pode já ter aplicado o valor.

A V4.2.2 atual usa agendamento mais agressivo para telemetria; em uma implementação industrial os timeouts devem ser configuráveis por perfil.

## 3. Convenções binárias fundamentais


- Todos os checksums conhecidos são **soma módulo 256**.
- Endereços de parâmetros são **16-bit little-endian**: `LO HI`.
- `uint16` e `int16` são little-endian.
- Resposta positiva: `53 LEN PAYLOAD... CK`.
- Status especial: `CA ... CK`.
- NAK/busy: `96 ... CK`.
- O eco da ECU deve ser removido **por igualdade exata da requisição**, não por busca ingênua de prefixo.

### 3.1 Checksum

```python
def checksum8(data: bytes) -> int:
    return sum(data) & 0xFF

def frame(body: bytes) -> bytes:
    return body + bytes([checksum8(body)])
```

Exemplos:
- `48 01` → checksum `49` → `48 01 49`;
- `09 7B 01` → checksum `85` → `09 7B 01 85`;
- `29 62 01` → checksum `8C` → `29 62 01 8C`.

## 4. Arquitetura industrial recomendada


### 4.1 Processos/threads

1. **Serial RX thread**
   Única função autorizada a chamar `receive/read`. Acumula bytes, remove eco, enquadra e enfileira pacotes.

2. **Transaction scheduler**
   Mantém uma transação pendente, prioridades e deadlines.

3. **Application dispatcher**
   Decodifica a resposta conforme o contexto da requisição.

4. **Persistence worker**
   SQLite, backup, retenção e exportação fora do caminho crítico.

5. **HTTP/UI worker**
   Serve snapshots imutáveis; nunca lê a porta serial diretamente.

6. **Learning/calibration worker**
   Processa amostras aceitas, sem bloquear telemetria.

### 4.2 Prioridades

```text
P0: segurança/encerramento
P1: telemetria página 1
P2: páginas auxiliares 4/5/0B
P3: leitura de K/AutoMatch/parâmetros
P4: escrita manual confirmada
P5: exportação e tarefas locais
```

Uma escrita deve pausar o polling, drenar RX, executar write + ACK + readback e só então retomar.

## 5. Máquina de transação de ponta a ponta


```text
IDLE
  ↓ enqueue(request, context, timeout)
TX_LOCK
  ↓ clear stale bytes / register expected echo
SEND
  ↓
WAIT_ECHO
  ├── mismatch → ECHO_ERROR
  └── exact match
WAIT_FRAME
  ├── timeout → TIMEOUT
  ├── 96 → NAK/BUSY
  ├── CA → STATUS
  └── 53 LEN ... CK
VALIDATE
  ├── bad length/checksum → PROTOCOL_ERROR
  └── valid
DISPATCH(context)
  ↓
COMPLETE / AUDIT
```

O `context` deve conter:
- `tx_id`;
- tipo (`telemetry`, `get_number`, `get_vector`, `set`, `command`);
- página/endereço/índices;
- tamanho esperado;
- timestamp;
- política de retry;
- hash do valor anterior em caso de escrita.

## 6. Conexão, sessão e encerramento


### 6.1 Sequência confirmada

| Fase | TX | RX típico | Confiança |
|---|---|---|---|
| Wake | `00` | sem frame obrigatório | C1 |
| Init 1 | `00 02 02` | `53 04 <4 bytes> <ck>` | C1 |
| Init 2 | `01 00 3A 3B` | `53 00 53` | C1 |
| Identificação | `00 25 25` | `53 01 02 56` no alvo | C3 |
| Encerramento de sessão | `01 12 00 13` | `53 00 53` | C3 |
| Disconnect | `00 01 01` | `53 00 53` | C1 |

Outros controles reais:
- `01 04 54 59` → `CA 01 10 DB` no alvo;
- `01 11 00 12` → ACK com payload `01/02`, provável mudança de modo/sessão.

### 6.2 Algoritmo

1. limpar fila de respostas e RX residual;
2. enviar `00`;
3. intervalo curto;
4. enviar Init 1 e exigir eco + ACK válido;
5. armazenar payload de identidade;
6. enviar Init 2;
7. identificação opcional;
8. iniciar polling;
9. watchdog reconecta após sequência de timeouts;
10. ao sair, tentar `01 12 00 13` e `00 01 01`.

## 7. Gramática das respostas


### 7.1 ACK

```text
53 LEN PAYLOAD[LEN] CHECKSUM
```

Total = `LEN + 3`.

### 7.2 NAK/Busy

```text
96 ... CHECKSUM
```

Não trate todo `0x96` como falha permanente. Registre contexto e aplique backoff.

### 7.3 Status CA

```text
CA LEN/STATUS ... CHECKSUM
```

`CA 01 10 DB` foi recorrente para recurso/página indisponível. O clone deve preservar payload completo e apresentar status técnico, sem descartá-lo como ruído.

## 8. Protocolo genérico de parâmetros


O SerialCode é endereço lógico de 16 bits. Não é offset da página de telemetria.

### 8.1 Leitura

| Operação | Corpo antes do checksum |
|---|---|
| Escalar | `09 LO HI` |
| Elemento de vetor | `0A LO HI INDEX` |
| Elemento de matriz | `0B LO HI INDEX_B INDEX_A` |
| Vetor completo | `29 LO HI` |
| Linha de matriz | `2A LO HI ROW` |

### 8.2 Escrita

Primeiro byte = base (`0x10` escalar/elemento, `0x30` vetor/linha) OR comprimento curto.
Para payload longo, low bits = `7` e há byte de tamanho estendido após `ADDR_LO`.

```python
def build_write(base, address, content):
    lo = address & 0xFF
    hi = address >> 8
    payload_len = 1 + len(content)        # inclui HI
    cmd = base | min(payload_len, 7)
    body = bytearray([cmd, lo])
    if payload_len >= 7:
        body.append(payload_len + 1)      # inclui LO já transmitido
    body.append(hi)
    body.extend(content)
    return body + bytes([sum(body) & 0xFF])
```

Exemplos observados:
- escrever `0` em `0x017B`: `12 7B 01 00 8E`;
- escrever `3000` (`B8 0B`) em `0x017A`: `13 7A 01 B8 0B 51`;
- célula K `0x0054`, índices no fio `07 02`, valor `B7`: `14 54 00 07 02 B7 28`.

**Atenção:** a ordem física dos índices é confirmada; o nome semântico linha/coluna deve ser ligado ao eixo por teste controlado.

## 9. Transformação raw ↔ unidade de engenharia


A transformação racional encontrada em `TLinearTransformation`:

```text
y = (A*x + B) / (C*x + D)
x = (B - D*y) / (C*y - A)
```

Ordem correta:
1. ler bytes;
2. aplicar endianness;
3. aplicar `DataMask`;
4. estender sinal quando `Signed=True`;
5. aplicar a fórmula;
6. arredondar apenas para UI, nunca para armazenamento interno.

Exemplos:
- `[1,0,0,512]`: `y=x/512`;
- `[1,0,0,1024]`: `y=x/1024`;
- `[1,0,0,16384]`: `y=x/16384`.

## 10. Telemetria rápida

### 10.1 Requests observados

| Função | TX/frame | RX | Confiança |
| --- | --- | --- | --- |
| Wake | 00 | sem resposta obrigatória | observado |
| Init etapa 1 | 00 02 02 | 53 04 <4 bytes> <ck> | observado |
| Init etapa 2 | 01 00 3A 3B | 53 00 53 | observado |
| Identificação/controle | 00 25 25 | 53 01 02 56 | observado; semântica exata ainda aberta |
| Desconectar | 00 01 01 | 53 00 53 | observado |
| Telemetria página 1 | 48 01 49 | 53 22 <34 bytes> <ck> | observado |
| Telemetria página 4 | 48 04 4C | 53 08 <8 bytes> <ck> | observado |
| Telemetria página 5 | 48 05 4D | 53 08 <8 bytes> <ck> | observado |
| Telemetria página 8 | 48 08 50 | CA 01 10 DB | observado como indisponível |
| Telemetria página 0B | 48 0B 53 | 53 0E <14 bytes> <ck> | observado |
| GetNumber v2 | 09 <lo> <hi> <ck> | 53 <len> <valor LE> <ck> | estático + observado |
| GetNumber elemento vetor v2 | 0A <lo> <hi> <index> <ck> | 53 <len> <valor LE> <ck> | estático + observado |
| GetNumber elemento matriz v2 | 0B <lo> <hi> <index2> <index1> <ck> | 53 <len> <valor LE> <ck> | estático; não visto nos logs |
| GetVector v2 | 29 <lo> <hi> <ck> | 53 <len> <dados LE> <ck> | estático + observado |
| GetVector linha de matriz v2 | 2A <lo> <hi> <row> <ck> | 53 <len> <linha> <ck> | estático + observado |
| SetNumber/elemento | (10\|N) <lo> [extlen] <hi> [índices] <dados> <ck> | 53 00 53 | estático + observado |
| SetVector/linha | (30\|N) <lo> [extlen] <hi> [row] <dados> <ck> | 53 00 53 | estático + observado |
| ACK positivo | 53 <len> <payload> <ck> | - | confirmado |
| Status/erro CA | CA <len/status...> <ck> | - | confirmado; bit 0x10 testado pelo app |
| NAK 96 | 96 <erro...> <ck> | - | confirmado por disassembly |


### 10.2 Agendamento


Requests:
- página 1: `48 01 49`;
- página 4: `48 04 4C`;
- página 5: `48 05 4D`;
- página 8: `48 08 50` (retornou CA no alvo);
- página 0B: `48 0B 53`.

Perfil recomendado:
```text
1,1,1,1,4,5
```
com página 1 prioritária. Não envie novo poll enquanto a transação anterior estiver pendente.

### 10.3 Layout completo conhecido

| Página | Offset | Bytes | Endian | Campo | Fórmula | Unidade | Confiança | Notas |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0x01 | d0-d1 | 2 | LE | RPM | uint16_le | rpm | confirmado/alto | Bate com logs, app e decoder atual. |
| 0x01 | d2 | 1 | - | nível/estado do comutador | raw ou tabela UI | índice | moderado | Usado como level no decoder; escala visual depende da configuração. |
| 0x01 | d3-d5 | 3 | - | não fechado | - | - | desconhecido | Reservar no clone; registrar bruto. |
| 0x01 | d6-d7 | 2 | LE | tempo de injeção de gás bruto | max(0,raw-d19-deadtime_counts)*0.00256 | ms | alto para posição; deadtime específico | Deadtime 234 counts no decoder atual é empírico/ECU-específico. |
| 0x01 | d8-d9 | 2 | LE | tempo de injeção gasolina bruto | max(0,raw-(d19 se GNV))*0.00256 | ms | alto | Variável central da telemetria/aprendizado. |
| 0x01 | d10 | 1 | - | não fechado | - | - | desconhecido | Registrar bruto. |
| 0x01 | d11 | 1 | - | estado de combustível | 0x80=gasolina;0x88=transição;0x90=GNV | enum | alto | Outros valores devem ser preservados. |
| 0x01 | d12 | 1 | - | temperatura da água | 124-raw | °C | forte empírico | Validar em mais ECUs/sensores. |
| 0x01 | d13 | 1 | - | não fechado | - | - | desconhecido | Registrar bruto. |
| 0x01 | d14-d15 | 2 | LE | pressão absoluta de gás sensor | offset + raw/divisor; perfil atual 1.60+raw/2550 | bar | posição alta; escala sensor-específica | Não universalizar coeficientes sem identificar sensor configurado. |
| 0x01 | d16 | 1 | - | temperatura do gás | raw (perfil atual) | °C | moderado | Pode usar tabela/offset em outras variantes. |
| 0x01 | d17-d18 | 2 | LE | MAP | raw/1000 | bar | alto | Informativo no projeto do usuário; AutoMatch original usa MAP. |
| 0x01 | d19 | 1 | - | correção dinâmica de contagens | subtrair de Tinj gasolina e gás quando em GNV | counts | alto no perfil analisado | Evita exibir correção embutida duas vezes. |
| 0x01 | d20-d33 | 14 | misto | canais/estados ainda não fechados | - | - | parcial | O app interno usa canais adicionais/lambda/voltagem/estados; offsets do buffer tratado não foram todos ligados ao frame bruto. |
| 0x04 | 0-7 | 8 | 4×uint16 LE | provável tempos gasolina por cilindro | raw*0.00256 ms (hipótese forte) | ms | provável | Amostras ~0x07xx; último canal às vezes FFFF. |
| 0x05 | 0-7 | 8 | 4×uint16 LE | provável tempos gás por cilindro | raw*0.00256 ms (hipótese forte) | ms | provável | Amostras ~0x11xx; último canal às vezes FFFF. |
| 0x08 | - | 0 | - | página indisponível no alvo capturado | resposta CA 01 10 DB | status | confirmado | Não interpretar como telemetria K. |
| 0x0B | 0-13 | 14 | misto | página de diagnóstico/status não fechada | - | - | observado, semântico aberto | Nos logs, quase toda zerada e byte final 0x03. |


### 10.4 Página 1 — decoder de referência


```python
rpm = u16le(payload, 0)
level_raw = payload[2]
gas_raw = u16le(payload, 6)
petrol_raw = u16le(payload, 8)
fuel_byte = payload[11]
water_raw = payload[12]
pressure_raw = u16le(payload, 14)
gas_temp_raw = payload[16]
map_raw = u16le(payload, 17)
dynamic_correction = payload[19]
```

Fórmulas comprovadas no perfil:
```text
RPM = d0 + 256*d1
Tinj_raw_ms = raw * 0.00256
MAP_bar = map_raw / 1000
```

Há dois perfis de pressão presentes no histórico do projeto:
- dossiê inicial/sensor específico: `1.60 + raw/2550`;
- V4.2.2 validada na tela/log correspondente: `raw/800`.

Logo, **pressão é dependente do sensor/configuração**. O aplicativo deve guardar `pressure_raw`, identificar o sensor e aplicar um perfil versionado. Nunca consolidar uma fórmula universal sem o código do sensor.

Temperatura da água também teve duas interpretações no histórico:
- fluxo anterior: `124 - raw`;
- V4.2.2 testada: `raw` direto.

A solução industrial é manter:
- `water_raw`;
- `water_c_profiled`;
- `temperature_profile_id`;
- comparação com a tela original por ECU/firmware.

### 10.5 Estado do combustível


| Byte | Estado |
|---|---|
| `0x80` | gasolina |
| `0x88` | transição/comutação |
| `0x90` | GNV |

Máquina robusta:
- `0x80` + `petrol_raw>0` → gasolina ativa;
- `0x88` + `gas_raw==0` → aguardando comutação;
- `0x88` + `gas_raw>0` → pulso GNV ainda em transição;
- `0x90` + `gas_raw>0` → GNV ativo;
- `0x90` + ambos zero após transição → possível cut-off, não declarar sem janela;
- valor desconhecido → preservar como `STATE_0xNN`.

### 10.6 Cut-off


Sem TPS/pedal/velocidade, o software só pode declarar **cut-off provável por pulsos**:
- RPM acima do limiar;
- petrol_raw = 0;
- gas_raw = 0;
- fora da janela de comutação;
- 3 ou mais frames consecutivos.

Estados: `INATIVO → CANDIDATO → PROVAVEL → RETORNO → INATIVO`.

## 11. Mapa K convencional


### 11.1 Endereços

| Nome | Endereço | Tipo | Leitura |
|---|---:|---|---|
| `TEMPI_PER_K` | `0x0037` | vetor uint16 | `29 37 00 <ck>` |
| `GIRI_PER_K` | `0x003D` | vetor uint16 | `29 3D 00 <ck>` |
| `MAP_K` | `0x0054` | matriz uint8 | `2A 54 00 ROW <ck>` |
| `MAPPA_DIFFERENZE_K` | `0x00D8` | matriz uint8 | `2A D8 00 ROW <ck>` |
| `RIGHE_MAPPAK_CALIBRATE` | `0x00EA` | vetor | `29 EA 00 <ck>` |

Eixos capturados:
- RPM: `850, 1350, 1850, 2500, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500`;
- Tinj: `2.00, 2.50, 3.00, 3.50, 4.50, 6, 8, 10, 12, 14, 16, 18 ms`.

### 11.2 Leitura completa

1. ler eixos;
2. para `row=0..11`, enviar `2A 54 00 row ck`;
3. aceitar payload de 12 bytes;
4. opcionalmente consultar linha `0x0C` porque a estrutura declarada diverge 13x12/12x12;
5. gerar assinatura SHA-1/SHA-256 da matriz;
6. armazenar snapshot raw, timestamp e identidade da ECU.

### 11.3 Escrita de célula

Exemplo real:
```text
14 54 00 07 02 B7 28
```

Procedimento obrigatório:
1. motor parado/condição de escrita validada;
2. backup completo;
3. ler célula atual;
4. montar SetNumber com dois índices;
5. enviar e validar ACK;
6. reler a linha;
7. comparar exatamente o raw;
8. registrar auditoria;
9. se divergente, rollback do snapshot.

A transformação física do raw K da matriz `0x0054` não foi declarada; trate como índice raw até prova por captura.

## 12. AutoMatch original


### 12.1 O que ele realmente faz

O AutoMatch original:
1. coleta curva gasolina `MAP × Tinj gasolina`;
2. coleta curva em GNV;
3. mantém buffers atual/anterior;
4. valida zonas e contadores;
5. calcula/atualiza `MUL_ACT`;
6. repete o processo conforme `NumAutomatch/MaxAutomatch`.

Não é correção instantânea e não é o mapa 2D RPM×Tinj usado pelo learning engine próprio.

### 12.2 Endereços principais

| Campo | Endereço | Fórmula |
|---|---:|---|
| Enable | `0x014A` | uint8 |
| Referências Tinj | `0x014B` | raw/512 ms |
| Referências MAP | `0x014C` | signed raw/1024 bar |
| Contadores gasolina | `0x015B` | uint16[] |
| Contadores GNV | `0x015C` | uint16[] |
| GNV anterior Tinj/MAP | `0x015D/0x015E` | /512, /1024 |
| GNV atual Tinj/MAP | `0x015F/0x0160` | /512, /1024 |
| Multiplicador atual | `0x0161` | raw/16384 |
| Gasolina Tinj/MAP | `0x0162/0x0163` | /512, /1024 |
| Zonas gasolina/GNV | `0x016F/0x0170` | 4 bytes |
| Nº executado | `0x0174` | uint8 |
| RPM máximo | `0x017A` | rpm |
| Deltas/diferenças | `0x0183..0x0188` | rpm, bar, ms |

### 12.3 Dimensões reais

Não confiar apenas no DFM:
- `PETR_INJ_TBP`, `MUL_ACT`, `MUL_ACT_EE`, `MUL_PREV_EE`, `0x018D`, `0x018E` retornaram **30 elementos**;
- buffers de aquisição principais permanecem com 18 pontos;
- o parser deve derivar a quantidade de elementos de `LEN/data_length`.

Referência real de Tinj da ECU capturada:
`0.5, 1.0, 1.5, ... 18, 20, 22 ms`.

### 12.4 Filtros padrão encontrados

| Parâmetro | Endereço | Default |
|---|---:|---:|
| Tempo mínimo habilitado | `0x0167[index 1]` | 1.0 s |
| Max RPM AutoMatch | `0x017A` | 3000 rpm |
| Diff RPM | `0x0183` | 400 rpm |
| Delta RPM | `0x0184` | 200 rpm |
| Diff MAP | `0x0185` | 0.5 bar |
| Delta MAP | `0x0186` | 0.05 bar |
| Diff Tinj | `0x0187` | 4.0 ms |
| Delta Tinj | `0x0188` | 1.0 ms |
| MaxAutomatch | `0x0165[index 2]` | 3 |

### 12.5 Comandos de ação

A chamada estática é `SendCommand(0x24,[0x04,mask],2,4)`. Pacotes reconstruídos, **C2**:
- reset gasolina: `02 24 04 01 2B`;
- reset GNV: `02 24 04 02 2C`;
- reset total: `02 24 04 04 2E`;
- manual AutoMatch: `02 24 04 08 32`.

Esses pacotes não foram capturados isoladamente no fio; um aplicativo industrial deve deixá-los bloqueados até teste de bancada e confirmação de ACK/readback.

## 13. Learning Engine próprio — RPM × Tinj gasolina


Esta é uma função própria do projeto, separada do AutoMatch original.

### 13.1 Regra de referência

- eixo 1: RPM;
- eixo 2: tempo de injeção da gasolina;
- banco A: carro operando na gasolina;
- banco B: tempo de gasolina observado com GNV ativo;
- tempo do injetor GNV é diagnóstico, não referência;
- MAP pode ser filtro de estabilidade, nunca eixo do mapa próprio.

### 13.2 Evidência real e interpolação

A arquitetura mais segura separa:
- **evidência real:** contador, média e variância da região realmente observada;
- **superfície de consulta:** interpolação/suavização calculada no momento da leitura;
- células vizinhas não ganham “amostra real” fictícia.

### 13.3 Estatística ponderada de Welford

Para amostra `x`, peso `w`, peso acumulado `W`, média `μ`:

```text
W' = W + w
δ = x - μ
μ' = μ + (w/W')·δ
M2' = M2 + w·δ·(x-μ')
σ = sqrt(M2'/W')
```

### 13.4 EMA com peso fracionário

Para alpha nominal `α` e peso `w`:

```text
α_eff = 1 - (1-α)^w
EMA' = EMA + α_eff·(x-EMA)
```

Isso impede que uma contribuição interpolada de peso 0,1 mova a média como uma amostra inteira.

### 13.5 Rejeição robusta

Mediana e MAD:
```text
MAD = mediana(|xi-mediana|)
σ_robusto = 1.4826·MAD
aceitar se |x-mediana| ≤ k·σ_robusto
```

Quando MAD=0, usar tolerância absoluta/percentual mínima.

### 13.6 Confiança

Modelo atual documentado:
```text
sample_score = clamp(weight/target_samples,0,1)
cv = std/|value|
variability_score = clamp(1-cv/max_cv,0,1)
update_score = clamp(updates/30,0,1)

confidence = 100·(
  0.55·sample_score +
  0.35·variability_score +
  0.10·update_score
)
```

### 13.7 Interpolação bilinear

Para `rpm` entre `r0/r1` e Tinj entre `t0/t1`:

```text
u=(rpm-r0)/(r1-r0)
v=(tinj-t0)/(t1-t0)

w00=(1-u)(1-v)
w10=u(1-v)
w01=(1-u)v
w11=uv
```

Consulta:
```text
V = Σ(wi·confidence_i·Vi) / Σ(wi·confidence_i)
```

A suavização em cruz pode ser uma camada posterior com kernel:
- centro: 1.0;
- cima/baixo/esquerda/direita: peso menor;
- sempre ponderado por confiança;
- nunca alterar contadores reais.

### 13.8 Erro e sugestão

```text
ratio = Tpet_GNV / Tpet_gasolina
erro% = (ratio-1)·100
K_ideal = K_atual·ratio
```

Aplicação amortecida:
```text
delta = clamp((ratio-1)·strength·confidence_factor, -max_step, +max_step)
K_sugerido = K_atual·(1+delta)
```

A sugestão deve ser separada em:
- instantânea;
- consolidada;
- validada por sessão;
- escrita somente manual e auditável.

## 14. Comutação gasolina/GNV e comandos operacionais


A telemetria confirma o estado por `d11`, mas o catálogo disponível não fecha com C1 um pacote universal de seleção de combustível.

Implementação industrial:
1. manter comandos observados em uma tabela de perfil por ECU;
2. exigir `control_unlocked`, motor parado ou política definida;
3. enviar comando;
4. exigir ACK;
5. confirmar mudança por sequência de frames `0x80/0x88/0x90`;
6. timeout → estado indeterminado e bloqueio;
7. nunca assumir sucesso apenas pelo ACK.

Quando o pacote não estiver C1, a UI deve dizer **“comando experimental não validado para este perfil”**.

## 15. Diagnóstico, freeze frame e testes


Funções encontradas:
- habilitação/estado de diagnóstico;
- DTC e freeze frame (`0x0178`, buffer 82 bytes);
- reset de freeze frame;
- teste on/off;
- exclusão/máscara de injetores;
- tempos de diagnóstico;
- sequência de injeção.

Os endereços estão no catálogo integral. Os pacotes de ações como limpar DTC/testar injetor não foram ligados de forma inequívoca a cada handler por captura unitária. Portanto:
- leitura pode ser implementada pelo motor genérico;
- escrita/ação deve ficar bloqueada por perfil até captura isolada.

## 16. Boot e flash


Comandos estáticos recuperados:
- cancel flash: `00 09 09`;
- exit boot: `00 0A 0A`;
- exit boot forçado: `00 0B 0B`;
- program flash: `93 93`;
- end flash: `85 85`.

O fluxo completo S19/HEX, baud de boot e blocos não foi capturado. Não é seguro construir um flasher apenas com essas constantes. O módulo de flash deve ser separado, desabilitado por padrão e só liberado após protocolo completo e recovery de bancada.

## 17. Persistência, auditoria e rollback


Tabelas mínimas:

```sql
ecu_identity(id, fingerprint, firmware, profile, first_seen, last_seen)
transactions(id, tx_id, timestamp, request_hex, response_hex, status, duration_ms, context_json)
telemetry_samples(id, timestamp, rpm, fuel, petrol_raw, petrol_ms, gas_raw, gas_ms, raw_payload)
parameter_snapshots(id, timestamp, address, indices, raw_blob, engineering_json, source)
k_snapshots(id, timestamp, axes_hash, matrix_blob, ecu_fingerprint, reason)
write_operations(id, timestamp, user, address, before_blob, requested_blob, ack, readback_blob, result)
automatch_sessions(id, start_at, end_at, counters_json, curves_json, result_json)
learning_cells(profile, fuel, rpm_index, inj_index, stats_json, updated_at)
events(id, timestamp, severity, category, detail_json)
```

Políticas:
- WAL;
- busy timeout;
- backup transacional;
- checksum/hash de snapshots;
- retenção de telemetria;
- nunca apagar histórico de escrita;
- rollback exige correspondência de fingerprint/firmware.

## 18. API e UI industrial


### 18.1 API

- `GET /api/health`
- `GET /api/session`
- `GET /api/telemetry`
- `GET /api/parameters/{address}`
- `POST /api/parameters/read`
- `POST /api/parameters/write` — autenticado, bloqueado por política
- `GET /api/k`
- `POST /api/k/cell`
- `POST /api/k/row`
- `POST /api/k/rollback`
- `GET /api/automatch`
- `POST /api/automatch/action`
- `GET /api/learning`
- `POST /api/export`

### 18.2 UI

Separar:
1. **Ao vivo** — RPM, tempos, combustível, temperaturas, pressão, link;
2. **Protocolo** — eco, ACK/NAK, timeouts, último frame raw;
3. **Parâmetros** — endereço, raw, unidade, origem e confiança;
4. **Mapa K** — valor ECU, sugestão e diferenças;
5. **AutoMatch** — curvas, zonas, contadores, ações;
6. **Learning** — evidência, confiança, maturidade e sessões;
7. **Escritas** — preview, backup, readback, rollback;
8. **Diagnóstico** — funções somente leitura e ações desbloqueáveis.

Cores nunca devem ser a única indicação: usar texto, ícone e estado.

## 19. Segurança de escrita


Checklist atômico:
1. identidade da ECU corresponde ao perfil;
2. tensão estável;
3. sessão saudável;
4. motor/ignição na condição exigida;
5. nenhuma transação pendente;
6. backup raw completo;
7. validação de limites, tamanho e transformação inversa;
8. preview hexadecimal;
9. confirmação explícita;
10. send;
11. ACK;
12. readback;
13. comparação byte a byte;
14. auditoria;
15. rollback automático/manual se divergente.

Jamais oferecer escrita automática em movimento.

## 20. Testes necessários para nível industrial


- unitários de checksum, endian, mask, signed e transformação;
- golden frames das páginas 1/4/5/0B;
- replay dos 13.356 pares request/response;
- fuzzing do parser com ruído e frames truncados;
- simulação de eco parcial/duplicado;
- timeouts e reconexão;
- teste de idempotência de leitura;
- escrita em ECU simulada;
- bancada real com readback e rollback;
- comparação de cada campo com a UI ProgBase;
- teste de dimensão variável 18/30;
- teste de banco corrompido e restauração;
- soak test de 8–24 horas;
- medição de latência e perda de frames.

## 21. Mapeamento da V4.2.2 atual

### 21.1 Funções presentes

```text
clamp
now_hms
now_timestamp
safe_print
log_event
bytes_hex
checksum8
append_checksum
checksum_ok
u16le
s16le
read_vector_cmd
read_scalar_cmd
nearest_index
bracket
surface_key
k_key
safe_mean
safe_pstdev
robust_accept
load_percent
new_stat_cell
weighted_update
cell_std
cell_value
cell_confidence
initialize_maps
update_k_signature_locked
decode_telemetry_payload
stability_assessment
detect_cutoff
distribute_surface_sample
learning_stage
update_learning
cross_smoothed_node
fallback_nearest_surface
surface_interpolate
k_interpolate
compute_live_ghost
build_ghost_cell
process_telemetry
ensure_android_dir
active_db_path
open_db
required_tables
create_schema
system_info_values
write_system_info
validate_db_file
unique_db_path
write_active_manifest
quarantine_database
create_new_database
select_active_database
initialize_db
reset_ram_maps
load_db
save_all_sync
prune_old_backups
backup_db_sync
db_worker
strip_expected_echo
extract_counted_packets
serial_reader_loop
serial_send
clear_rx_queue
wait_packet
handshake_step
perform_handshake
pending_snapshot
start_transaction
clear_pending_if_matches
service_transaction_timeout
smart_window_for_background_reads
start_k_cycle
schedule_k_if_possible
start_aux_cycle
schedule_aux_if_possible
start_diff_cycle
schedule_diff_if_possible
scheduler_step
apply_k_row
decode_aux_data
dispatch_packet
service_rx_queue
compact_surface
compact_ghost
compact_k
state_snapshot
export_json_sync
send_http
web_server_loop
run_self_tests
console_status
print_banner
graceful_shutdown
main
```

### 21.2 Configurações da V4.2.2

```json
{
  "aux_auto_read": 1,
  "aux_item_gap_sec": 1.5,
  "aux_refresh_interval_sec": 180.0,
  "aux_timeout_sec": 0.18,
  "backup_interval_sec": 180.0,
  "backup_keep_count": 12,
  "console_interval_sec": 3.0,
  "correction_strength": 0.7,
  "cross_neighbor_weight": 0.24,
  "cutoff_confirm_frames": 3,
  "cutoff_min_rpm": 1200,
  "diff_map_auto_read": 0,
  "ema_fast_alpha": 0.3,
  "ema_mid_alpha": 0.1,
  "ema_slow_alpha": 0.01,
  "fallback_search_radius": 3,
  "ghost_deadband_ms": 0.06,
  "ghost_deadband_pct": 1.25,
  "ghost_min_confidence": 65.0,
  "handshake_gap_sec": 0.08,
  "handshake_retries": 3,
  "handshake_timeout_sec": 1.5,
  "history_points": 180,
  "ignore_after_fuel_switch_sec": 1.0,
  "k_auto_read": 1,
  "k_max": 255.0,
  "k_min": 50.0,
  "k_min_stable_ms": 1500,
  "k_read_extra_row_manual": 1,
  "k_refresh_interval_sec": 60.0,
  "k_row_gap_sec": 0.8,
  "k_timeout_sec": 0.13,
  "learn_mode": "AUTO",
  "learning_enabled": 1,
  "main_loop_sleep_sec": 0.004,
  "mature_effective_samples": 75.0,
  "max_consecutive_telemetry_timeouts": 5,
  "max_correction_ratio_per_step": 0.15,
  "max_cv_for_full_confidence": 0.08,
  "max_gas_pressure_span_bar": 0.25,
  "max_load_span_bar": 0.06,
  "max_petrol_span_ms": 0.55,
  "max_rpm": 7000,
  "max_rpm_cv": 0.045,
  "max_rpm_span": 240.0,
  "max_rx_buffer": 8192,
  "min_cell_dwell_ms": 80,
  "min_coolant_c": 35.0,
  "min_learning_quality": 0.2,
  "min_node_confidence": 8.0,
  "min_petrol_ms": 0.65,
  "min_rpm": 600,
  "min_window_duration_sec": 0.12,
  "outlier_mad_sigma": 3.5,
  "recent_robust_window": 31,
  "reconnect_delay_sec": 1.5,
  "save_interval_sec": 6.0,
  "serial_idle_sleep_sec": 0.004,
  "stability_window": 4,
  "target_effective_samples": 30.0,
  "telemetry_interval_sec": 0.12,
  "telemetry_timeout_sec": 0.24,
  "watchdog_telemetry_sec": 3.0,
  "web_accept_timeout_sec": 1.0
}
```


A V4.2.2 é explicitamente read-only e já contém:
- parser/eco/checksum;
- telemetria;
- leitura inteligente de linhas K;
- leitura de buffers auxiliares;
- Welford/EMA/MAD;
- interpolação e fantasma;
- banco e painel.

Para atingir o fluxo deste guia, faltam nela, principalmente:
- motor genérico completo de escrita;
- write/readback/rollback;
- perfil C1 de comutação;
- AutoMatch acionável com comandos confirmados;
- diagnóstico ativo validado;
- catálogo integral exposto na aplicação.

## 22. Lacunas conhecidas — não inventar


| Item | Estado |
|---|---|
| Bytes d3–d5, d10, d13, d20–d33 da página 1 | Semântica incompleta; registrar raw. |
| Páginas 4/5 | Forte hipótese de tempos por cilindro, ainda exigir correlação controlada. |
| Página 0B | Payload observado, semântica aberta. |
| Escala universal de pressão/temperatura | Dependente de sensor/perfil. |
| Fórmula interna exata do firmware AutoMatch → MUL_ACT | Não está integralmente no PC. |
| Pacotes de ação AutoMatch | C2, reconstruídos estaticamente, não capturados isoladamente. |
| Comutação combustível universal | Não fechada em C1 no catálogo apresentado. |
| Limpar DTC/testes ativos | Precisam de captura unitária. |
| Flash completo | Incompleto e perigoso. |
| Fator físico da matriz K raw 0x0054 | Não declarado; manter raw. |

## APÊNDICE A — Dimensões observadas dos parâmetros

| Decimal | Hex | Componentes | Classe | Bytes/elem | Dimensão DFM | Payload observado | Elementos observados | Request | Respostas | Divergência |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 3 | 0x0003 | FLAG_CONF1 | TAebVector | 2 | 2 | 4 | 2 | 29 03 00 2C | 16 | False |
| 12 | 0x000C | RIF_GIRI | TAebVector | 2 | 12 | 24 | 12 | 29 0C 00 35 | 8 | False |
| 28 | 0x001C | ABIL_DIAGNOSI | TAebVector | 1 | 5 | 5 | 5 | 29 1C 00 45 | 8 | False |
| 29 | 0x001D | STATO_DIAGNOSI | TAebVector | 1 | 5 | 5 | 5 | 29 1D 00 46 | 1124 | False |
| 37 | 0x0025 | RIF_SENSORE | TAebVector | 1 | 4 | 4 | 4 | 29 25 00 4E | 8 | False |
| 42 | 0x002A | RIF_TEMP_GAS_LR \| RIF_TEMP_RID | TAebVector | 1 | 10 | 10 | 10 | 29 2A 00 53 | 8 | False |
| 43 | 0x002B | COEFF_TEMP_GAS_LR \| COEFF_TEMP_RID | TAebVector | 1 | 9 | 9 | 9 | 29 2B 00 54 | 8 | False |
| 47 | 0x002F | RIF_DELAY_GAS_TEMP | TAebVector | 1 | 9 | 9 | 9 | 29 2F 00 58 | 8 | False |
| 50 | 0x0032 | GIRI_CUTOFF_LR \| GIRI_TEMPO_CUTOFF | TAebNumber \| TAebVector | 2 | 2 | 4 | 2 | 29 32 00 5B | 8 | False |
| 53 | 0x0035 | IDENTIFICATIVO | TAebVector | 1 | 30 | 30 | 30 | 29 35 00 5E | 8 | False |
| 55 | 0x0037 | TEMPI_PER_K | TAebVector | 2 | 12 | 24 | 12 | 29 37 00 60 | 8 | False |
| 61 | 0x003D | GIRI_PER_K | TAebVector | 2 | 12 | 24 | 12 | 29 3D 00 66 | 8 | False |
| 74 | 0x004A | TEMPO_MAX_CORRENTE | TAebVector | 2 | 2 | 4 | 2 | 29 4A 00 73 | 8 | False |
| 81 | 0x0051 | TEMP_DIAGNOSI | TAebVector | 1 | 4 | 4 | 4 | 29 51 00 7A | 8 | False |
| 86 | 0x0056 | TEMPI_SECONDI | TAebVector | 2 | 3 | 6 | 3 | 29 56 00 7F | 2 | False |
| 92 | 0x005C | RIF_TEMP_GAS \| RIF_TEMP_RID_LR | TAebVector | 1 | 10 | 10 | 10 | 29 5C 00 85 | 8 | False |
| 93 | 0x005D | COEFF_TEMP_GAS \| COEFF_TEMP_RID_LR | TAebVector | 1 | 9 | 9 | 9 | 29 5D 00 86 | 8 | False |
| 95 | 0x005F | RIF_PRESS_COLL | TAebVector | 2 | 15 | 30 | 15 | 29 5F 00 88 | 8 | False |
| 96 | 0x0060 | COEFF_PRESS_COLL | TAebVector | 2 | 15 | 30 | 15 | 29 60 00 89 | 8 | False |
| 111 | 0x006F | RIF_MAP_SONDA_LAMBDA \| RITARDO_PASSAGGIO_GAS_LR | TAebVector | 2 | 4 \| 8 | 8 | 4 | 29 6F 00 98 | 8 | False |
| 114 | 0x0072 | MAP_BENZINA_LR \| MAP_FILTRO_BENZINA | TAebMatrix \| TAebVector | 2 | 12 | 24 | 12 | 29 72 00 9B | 8 | False |
| 120 | 0x0078 | MAP_ESTERNO | TAebVector | 2 | 6 | 12 | 6 | 29 78 00 A1 | 8 | False |
| 123 | 0x007B | RIF_PRESS_DIFF | TAebVector | 2 | 15 | 30 | 15 | 29 7B 00 A4 | 8 | False |
| 124 | 0x007C | COEFF_PRESS_DIFF | TAebVector | 2 | 15 | 30 | 15 | 29 7C 00 A5 | 8 | False |
| 127 | 0x007F | TEMPI_K_OPENLOOP | TAebVector | 2 | 12 | 24 | 12 | 29 7F 00 A8 | 8 | False |
| 130 | 0x0082 | RIF_SONDA_LAMBDA | TAebVector | 1 | 12 | 12 | 12 | 29 82 00 AB | 8 | False |
| 131 | 0x0083 | RIT_EMUL_RICCA | TAebVector | 2 | 12 | 24 | 12 | 29 83 00 AC | 8 | False |
| 138 | 0x008A | PARAMETRI_TEMP | TAebVector | 1 | 5 | 5 | 5 | 29 8A 00 B3 | 8 | False |
| 139 | 0x008B | ECU_TEMP | TAebVector | 1 | 30 | 30 | 30 | 29 8B 00 B4 | 8 | False |
| 145 | 0x0091 | SCARTO_MINIMO_TARATURA | TAebVector | 2 | 2 | 4 | 2 | 29 91 00 BA | 8 | False |
| 148 | 0x0094 | TIPO_INIETTORE | TAebVector | 1 | 2 | 2 | 2 | 29 94 00 BD | 16 | False |
| 151 | 0x0097 | PARAM_AUTOTARATURA | TAebVector | 1 | 3 | 3 | 3 | 29 97 00 C0 | 8 | False |
| 152 | 0x0098 | PRESS_BASSA_RETROPAS_LR \| TINJ_FILTRO | TAebNumber \| TAebVector | 2 | 8 | 16 | 8 | 29 98 00 C1 | 8 | False |
| 155 | 0x009B | TEMPI_EXTRAINIETTATE | TAebVector | 2 | 3 | 6 | 3 | 29 9B 00 C4 | 8 | False |
| 158 | 0x009E | CORRETTORE_BANCATA2 \| TEMPERATURA_ACQUA_AVVIO_LR | TAebVector | 1 | 9 \| 12 | 12 | 12 | 29 9E 00 C7 | 8 | False |
| 160 | 0x00A0 | SEQUENZA_INJ_LR \| TEMPI_PER_BENZINA | TAebMatrix \| TAebVector | 2 | 4 | 8 | 4 | 29 A0 00 C9 | 8 | False |
| 161 | 0x00A1 | GIRI_PER_BENZINA \| SEQUENZA_INJ_BENZ_LR | TAebVector | 2 | 2 \| 8 | 4 | 2 | 29 A1 00 CA | 8 | False |
| 163 | 0x00A3 | INIETTATE_PER_BENZINA \| RIF_MAP_ANTICIPO_LR | TAebVector | 1 | 2 \| 5 | 2 | 2 | 29 A3 00 CC | 8 | False |
| 170 | 0x00AA | EMULAZIONE_POSTERIORE | TAebVector | 1 | 2 | 2 | 2 | 29 AA 00 D3 | 8 | False |
| 189 | 0x00BD | CONFIGURA_ADATTA_LR \| PRESS_RETROPASSAGGIO | TAebVector | 2 | 2 \| 12 | 24 | 12 | 29 BD 00 E6 | 8 | False |
| 192 | 0x00C0 | FLAG_CONF2 | TAebVector | 2 | 2 | 4 | 2 | 29 C0 00 E9 | 8 | False |
| 194 | 0x00C2 | MASK_FUNCTION | TAebVector | 1 | 30 | 30 | 30 | 29 C2 00 EB | 10 | False |
| 196 | 0x00C4 | RIF_PRESS_SPLIT_FUEL | TAebVector | 1 | 10 | 10 | 10 | 29 C4 00 ED | 8 | False |
| 197 | 0x00C5 | COEFF_PRESS_SPLIT_FUEL | TAebVector | 1 | 10 | 10 | 10 | 29 C5 00 EE | 8 | False |
| 198 | 0x00C6 | K_FACTOR_PARAM | TAebVector | 2 | 4 | 8 | 4 | 29 C6 00 EF | 8 | False |
| 219 | 0x00DB | ADVANCED_PARAM_INJ | TAebVector | 2 | 6 | 12 | 6 | 29 DB 00 04 | 8 | False |
| 220 | 0x00DC | TEMPERATURA_ACQUA_AVVIO | TAebVector | 1 | 9 | 9 | 9 | 29 DC 00 05 | 8 | False |
| 221 | 0x00DD | RITARDO_PASSAGGIO | TAebVector | 1 | 8 | 8 | 8 | 29 DD 00 06 | 8 | False |
| 223 | 0x00DF | RIF_PRESS_ASS | TAebVector | 1 | 15 | 15 | 15 | 29 DF 00 08 | 8 | False |
| 224 | 0x00E0 | COEFF_PRESS_ASS | TAebVector | 2 | 15 | 30 | 15 | 29 E0 00 09 | 8 | False |
| 226 | 0x00E2 | CHANGE_OVER_CILYNDER_DELAY | TAebVector | 2 | 4 | 8 | 4 | 29 E2 00 0B | 8 | False |
| 227 | 0x00E3 | FREST_PARAMETER_LR \| SERVICE_DATA | TAebVector | 1 | 6 \| 25 | 35 | 35 | 29 E3 00 0C | 8 | True |
| 231 | 0x00E7 | ADVANCED_TEMP_RID | TAebVector | 1 | 4 | 4 | 4 | 29 E7 00 10 | 8 | False |
| 232 | 0x00E8 | ADVANCED_PRESS_BACK | TAebVector | 2 | 2 | 4 | 2 | 29 E8 00 11 | 8 | False |
| 237 | 0x00ED | PARAMETRI_TAGLIANDI | TAebVector | 1 | 3 | 3 | 3 | 29 ED 00 16 | 8 | False |
| 238 | 0x00EE | TEMPI_ANTICIPI_EV | TAebVector | 1 | 2 | 2 | 2 | 29 EE 00 17 | 8 | False |
| 241 | 0x00F1 | ADV_PARAM_INJ | TAebVector | 2 | 12 | 24 | 12 | 29 F1 00 1A | 8 | False |
| 242 | 0x00F2 | ADV_OFFSET_INJ_PETROL | TAebVector | 1 | 10 | 10 | 10 | 29 F2 00 1B | 8 | False |
| 243 | 0x00F3 | ADV_OFFSET_INJ_GAS | TAebVector | 1 | 10 | 10 | 10 | 29 F3 00 1C | 8 | False |
| 248 | 0x00F8 | FLASH_LUBE_PARAMETER | TAebVector | 2 | 4 | 8 | 4 | 29 F8 00 21 | 8 | False |
| 250 | 0x00FA | FLAG_CONF3 | TAebVector | 2 | 2 | 4 | 2 | 29 FA 00 23 | 8 | False |
| 307 | 0x0133 | ANTI_STALLO | TAebVector | 2 | 5 | 10 | 5 | 29 33 01 5D | 8 | False |
| 312 | 0x0138 | PARAM_VARI | TAebVector | 2 | 10 | 20 | 10 | 29 38 01 62 | 8 | False |
| 331 | 0x014B | PETR_INJ_TBP | TAebVector | 2 | 18 | 60 | 30 | 29 4B 01 75 | 8 | True |
| 332 | 0x014C | MNFLD_PRESS_THD | TAebVector | 2 | 18 | 36 | 18 | 29 4C 01 76 | 8 | False |
| 334 | 0x014E | PETR_INJ_TBUF_GAS_EE | TAebVector | 2 | 18 | 36 | 18 | 29 4E 01 78 | 8 | False |
| 335 | 0x014F | PETR_INJ_TBUF_GAS_PREV_EE | TAebVector | 2 | 18 | 36 | 18 | 29 4F 01 79 | 8 | False |
| 336 | 0x0150 | PETR_INJ_TBUF_PETR_EE | TAebVector | 2 | 18 | 36 | 18 | 29 50 01 7A | 8 | False |
| 337 | 0x0151 | MNFLD_PRESS_BUF_GAS_EE | TAebVector | 2 | 18 | 36 | 18 | 29 51 01 7B | 8 | False |
| 338 | 0x0152 | MNFLD_PRESS_BUF_GAS_PREV_EE | TAebVector | 2 | 18 | 36 | 18 | 29 52 01 7C | 8 | False |
| 339 | 0x0153 | MNFLD_PRESS_BUF_PETR_EE | TAebVector | 2 | 18 | 36 | 18 | 29 53 01 7D | 8 | False |
| 340 | 0x0154 | BUF_UPD_GAS_EE | TAebVector | 2 | 18 | 36 | 18 | 29 54 01 7E | 8 | False |
| 341 | 0x0155 | BUF_UPD_PETR_EE | TAebVector | 2 | 18 | 36 | 18 | 29 55 01 7F | 8 | False |
| 342 | 0x0156 | VECT_EE_S16 | TAebVector | 2 | 3 | 6 | 3 | 29 56 01 80 | 8 | False |
| 343 | 0x0157 | VECT_EE_U16 | TAebVector | 2 | 3 | 6 | 3 | 29 57 01 81 | 8 | False |
| 344 | 0x0158 | MUL_ACT_EE | TAebVector | 2 | 18 | 60 | 30 | 29 58 01 82 | 8 | True |
| 345 | 0x0159 | MUL_PREV_EE | TAebVector | 2 | 18 | 60 | 30 | 29 59 01 83 | 8 | True |
| 347 | 0x015B | NUM_BUF_UPD_PETR | TAebVector | 2 | 18 | 36 | 18 | 29 5B 01 85 | 16 | False |
| 348 | 0x015C | NUM_BUF_UPD_GAS | TAebVector | 2 | 18 | 36 | 18 | 29 5C 01 86 | 17 | False |
| 349 | 0x015D | PETR_INJ_TBUF_GAS_PREV | TAebVector | 2 | 18 | 36 | 18 | 29 5D 01 87 | 16 | False |
| 350 | 0x015E | MNFLD_PRESS_BUF_GAS_PREV | TAebVector | 2 | 18 | 36 | 18 | 29 5E 01 88 | 16 | False |
| 351 | 0x015F | PETR_INJ_TBUF_GAS | TAebVector | 2 | 18 | 36 | 18 | 29 5F 01 89 | 17 | False |
| 352 | 0x0160 | MNFLD_PRESS_BUF_GAS | TAebVector | 2 | 18 | 36 | 18 | 29 60 01 8A | 17 | False |
| 353 | 0x0161 | MUL_ACT | TAebVector | 2 | 18 | 60 | 30 | 29 61 01 8B | 15 | True |
| 354 | 0x0162 | PETR_INJ_TBUF | TAebVector | 2 | 18 | 36 | 18 | 29 62 01 8C | 16 | False |
| 355 | 0x0163 | MNFLD_PRESS_BUF | TAebVector | 2 | 18 | 36 | 18 | 29 63 01 8D | 16 | False |
| 367 | 0x016F | ACQUIRED_ZONES_PETROL | TAebVector | 1 | 4 | 4 | 4 | 29 6F 01 99 | 5 | False |
| 368 | 0x0170 | ACQUIRED_ZONES_GAS | TAebVector | 1 | 4 | 4 | 4 | 29 70 01 9A | 2 | False |
| 370 | 0x0172 | CALIBRATION_VAL_1 | TAebVector | 1 | 10 | 10 | 10 | 29 72 01 9C | 8 | False |
| 377 | 0x0179 | ABIL_FREEZEFRAME | TAebVector | 1 | 5 | 5 | 5 | 29 79 01 A3 | 8 | False |
| 397 | 0x018D | PETR_MNFLD_PRESS_RV | TAebVector | 2 | 18 | 60 | 30 | 29 8D 01 B7 | 6 | True |
| 398 | 0x018E | GAS_MNFLD_PRESS_RV | TAebVector | 2 | 18 | 60 | 30 | 29 8E 01 B8 | 6 | True |


## APÊNDICE B — Catálogo integral dos 388 parâmetros

> Cada registro abaixo preserva todos os metadados disponíveis. Campos “—” não foram declarados no artefato.

### 0x0001 — `REGISTRO_INIT` (TSTREAMDATI)

- **Caminho:** `StreamDati/REGISTRO_INIT`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `1`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 01 00 <ck>`

- **Escrita v2:** `12 01 00 <1 byte(s) LE> <ck>`

### 0x0002 — `REGISTRO_EE` (TSTREAMDATI)

- **Caminho:** `StreamDati/REGISTRO_EE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `2`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 02 00 <ck>`

- **Escrita v2:** `12 02 00 <1 byte(s) LE> <ck>`

### 0x0003 — `FLAG_CONF1` (TSTREAMDATI)

- **Caminho:** `StreamDati/FLAG_CONF1`

- **Classe:** `TAebVector`; **SerialCode decimal:** `3`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 03 00 <ck>`

- **Escrita v2:** `35 03 00 <4 bytes LE> <ck>`

### 0x0004 — `TIPO_LAMBDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_LAMBDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `4`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 04 00 <ck>`

- **Escrita v2:** `12 04 00 <1 byte(s) LE> <ck>`

### 0x0005 — `RIF_LAMBDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_LAMBDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `5`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 05 00 <ck>`

- **Escrita v2:** `12 05 00 <1 byte(s) LE> <ck>`

### 0x0006 — `RITARDO_SONDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_SONDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `6`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 06 00 <ck>`

- **Escrita v2:** `12 06 00 <1 byte(s) LE> <ck>`

### 0x0007 — `TEMPO_LBD_FREDDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_LBD_FREDDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `7`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 07 00 <ck>`

- **Escrita v2:** `12 07 00 <1 byte(s) LE> <ck>`

### 0x0008 — `RIF_SUP_LAMBDA_FREDDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_SUP_LAMBDA_FREDDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `8`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 08 00 <ck>`

- **Escrita v2:** `12 08 00 <1 byte(s) LE> <ck>`

### 0x0009 — `RIF_INF_LAMBDA_FREDDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_INF_LAMBDA_FREDDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `9`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 09 00 <ck>`

- **Escrita v2:** `12 09 00 <1 byte(s) LE> <ck>`

### 0x000A — `RIF_SUP_LAMBDA_CALDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_SUP_LAMBDA_CALDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `10`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 0A 00 <ck>`

- **Escrita v2:** `12 0A 00 <1 byte(s) LE> <ck>`

### 0x000B — `RIF_INF_LAMBDA_CALDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_INF_LAMBDA_CALDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `11`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 0B 00 <ck>`

- **Escrita v2:** `12 0B 00 <1 byte(s) LE> <ck>`

### 0x000C — `RIF_GIRI` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_GIRI`

- **Classe:** `TAebVector`; **SerialCode decimal:** `12`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 0C 00 <ck>`

- **Escrita v2:** `37 0C 1A 00 <24 bytes LE> <ck>`

### 0x000D — `DIAGNOSI_SWITCHON_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/DIAGNOSI_SWITCHON_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `13`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 0D 00 <ck>`

- **Escrita v2:** `36 0D 00 <5 bytes LE> <ck>`

### 0x000D — `SEQUENZA_INIEZIONE` (TSTREAMDATI)

- **Caminho:** `StreamDati/SEQUENZA_INIEZIONE`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `13`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 0D 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 0D <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x000E — `SEQUENZA_INIEZIONE_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/SEQUENZA_INIEZIONE_BENZINA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `14`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 0E 00 <ck>`

- **Escrita v2:** `37 0E 0A 00 <8 bytes LE> <ck>`

### 0x000F — `TEMP_GAS_CAMBIO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMP_GAS_CAMBIO_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `15`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 0F 00 <ck>`

- **Escrita v2:** `12 0F 00 <1 byte(s) LE> <ck>`

### 0x000F — `TEMP_RID_CAMBIO` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMP_RID_CAMBIO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `15`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 0F 00 <ck>`

- **Escrita v2:** `12 0F 00 <1 byte(s) LE> <ck>`

### 0x0010 — `GIRI_MIN_CAMBIO` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_MIN_CAMBIO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `16`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 10 00 <ck>`

- **Escrita v2:** `13 10 00 <2 byte(s) LE> <ck>`

### 0x0011 — `RITARDO_CAMBIO` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_CAMBIO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `17`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 11 00 <ck>`

- **Escrita v2:** `12 11 00 <1 byte(s) LE> <ck>`

### 0x0012 — `TEST_WORD` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEST_WORD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `18`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 12 00 <ck>`

- **Escrita v2:** `13 12 00 <2 byte(s) LE> <ck>`

### 0x0013 — `CS_PCB_WORD_ARRAY` (TSTREAMDATI)

- **Caminho:** `StreamDati/CS_PCB_WORD_ARRAY`

- **Classe:** `TAebVector`; **SerialCode decimal:** `19`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 13 00 <ck>`

- **Escrita v2:** `35 13 00 <4 bytes LE> <ck>`

### 0x0014 — `TIPO_ACCENS` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_ACCENS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `20`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 14 00 <ck>`

- **Escrita v2:** `12 14 00 <1 byte(s) LE> <ck>`

### 0x0015 — `MODELLO_HARDWARE` (TSTREAMDATI)

- **Caminho:** `StreamDati/MODELLO_HARDWARE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `21`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 15 00 <ck>`

- **Escrita v2:** `12 15 00 <1 byte(s) LE> <ck>`

### 0x0016 — `SMAGRIMENTO_EXTRA` (TSTREAMDATI)

- **Caminho:** `StreamDati/SMAGRIMENTO_EXTRA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `22`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 16 00 <ck>`

- **Escrita v2:** `12 16 00 <1 byte(s) LE> <ck>`

### 0x0016 — `TAGLIA_INIETTORE_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TAGLIA_INIETTORE_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `22`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 16 00 <ck>`

- **Escrita v2:** `12 16 00 <1 byte(s) LE> <ck>`

### 0x0017 — `TEST_BYTE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEST_BYTE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `23`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 17 00 <ck>`

- **Escrita v2:** `12 17 00 <1 byte(s) LE> <ck>`

### 0x0018 — `TEST_TEMPO` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEST_TEMPO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `24`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 18 00 <ck>`

- **Escrita v2:** `13 18 00 <2 byte(s) LE> <ck>`

### 0x0019 — `TEST_BYTE_ARRAY` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEST_BYTE_ARRAY`

- **Classe:** `TAebVector`; **SerialCode decimal:** `25`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 19 00 <ck>`

- **Escrita v2:** `37 19 0C 00 <10 bytes LE> <ck>`

### 0x001B — `NOTE_CONFIG` (TSTREAMDATI)

- **Caminho:** `StreamDati/NOTE_CONFIG`

- **Classe:** `TAebVector`; **SerialCode decimal:** `27`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `48.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[48, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 1B 00 <ck>`

- **Escrita v2:** `37 1B 32 00 <48 bytes LE> <ck>`

### 0x001C — `ABIL_DIAGNOSI` (TSTREAMDATI)

- **Caminho:** `StreamDati/ABIL_DIAGNOSI`

- **Classe:** `TAebVector`; **SerialCode decimal:** `28`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 1C 00 <ck>`

- **Escrita v2:** `36 1C 00 <5 bytes LE> <ck>`

### 0x001D — `STATO_DIAGNOSI` (TSTREAMDATI)

- **Caminho:** `StreamDati/STATO_DIAGNOSI`

- **Classe:** `TAebVector`; **SerialCode decimal:** `29`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 1D 00 <ck>`

- **Escrita v2:** `36 1D 00 <5 bytes LE> <ck>`

### 0x001E — `DATA_ULTIMO_SCARICO` (TSTREAMDATI)

- **Caminho:** `StreamDati/DATA_ULTIMO_SCARICO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `30`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 1E 00 <ck>`

- **Escrita v2:** `13 1E 00 <2 byte(s) LE> <ck>`

### 0x001F — `ACTION_DIAGNOSI` (TSTREAMDATI)

- **Caminho:** `StreamDati/ACTION_DIAGNOSI`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `31`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 1F 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 1F <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x001F — `TEMPO_CICCHETTO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_CICCHETTO_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `31`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 1F 00 <ck>`

- **Escrita v2:** `12 1F 00 <1 byte(s) LE> <ck>`

### 0x0020 — `DIAGNOSI_INJ_GAS` (TSTREAMDATI)

- **Caminho:** `StreamDati/DIAGNOSI_INJ_GAS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `32`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 20 00 <ck>`

- **Escrita v2:** `12 20 00 <1 byte(s) LE> <ck>`

### 0x0020 — `PARAM_VARI_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_VARI_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `32`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 800.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`ParamVari`, key=`Value`; connection=`AebConnection`

- **Leitura v2:** `29 20 00 <ck>`

- **Escrita v2:** `37 20 16 00 <20 bytes LE> <ck>`

### 0x0021 — `DIAGNOSI_INJ_BENZ` (TSTREAMDATI)

- **Caminho:** `StreamDati/DIAGNOSI_INJ_BENZ`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `33`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 21 00 <ck>`

- **Escrita v2:** `12 21 00 <1 byte(s) LE> <ck>`

### 0x0022 — `DIAGNOSI_INJ_GAS2` (TSTREAMDATI)

- **Caminho:** `StreamDati/DIAGNOSI_INJ_GAS2`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `34`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 22 00 <ck>`

- **Escrita v2:** `12 22 00 <1 byte(s) LE> <ck>`

### 0x0023 — `DIAGNOSI_INJ_BENZ2` (TSTREAMDATI)

- **Caminho:** `StreamDati/DIAGNOSI_INJ_BENZ2`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `35`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 23 00 <ck>`

- **Escrita v2:** `12 23 00 <1 byte(s) LE> <ck>`

### 0x0024 — `TIPO_SENSORE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_SENSORE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `36`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 24 00 <ck>`

- **Escrita v2:** `12 24 00 <1 byte(s) LE> <ck>`

### 0x0025 — `RIF_SENSORE` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_SENSORE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `37`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 25 00 <ck>`

- **Escrita v2:** `35 25 00 <4 bytes LE> <ck>`

### 0x0026 — `GIRI_ANTICIPO` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_ANTICIPO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `38`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 26 00 <ck>`

- **Escrita v2:** `37 26 12 00 <16 bytes LE> <ck>`

### 0x0027 — `COEFF_ANTICIPO` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_ANTICIPO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `39`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 27 00 <ck>`

- **Escrita v2:** `37 27 0A 00 <8 bytes LE> <ck>`

### 0x002A — `RIF_TEMP_GAS_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_TEMP_GAS_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `42`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 2A 00 <ck>`

- **Escrita v2:** `37 2A 0C 00 <10 bytes LE> <ck>`

### 0x002A — `RIF_TEMP_RID` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_TEMP_RID`

- **Classe:** `TAebVector`; **SerialCode decimal:** `42`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 2A 00 <ck>`

- **Escrita v2:** `37 2A 0C 00 <10 bytes LE> <ck>`

### 0x002B — `COEFF_TEMP_GAS_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_TEMP_GAS_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `43`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 2B 00 <ck>`

- **Escrita v2:** `37 2B 0B 00 <9 bytes LE> <ck>`

### 0x002B — `COEFF_TEMP_RID` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_TEMP_RID`

- **Classe:** `TAebVector`; **SerialCode decimal:** `43`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 2B 00 <ck>`

- **Escrita v2:** `37 2B 0B 00 <9 bytes LE> <ck>`

### 0x002C — `MAPPA_ANTICIPO` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_ANTICIPO`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `44`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 2C 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 2C <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x002D — `MAP_ANTICIPO` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAP_ANTICIPO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `45`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 2D 00 <ck>`

- **Escrita v2:** `36 2D 00 <5 bytes LE> <ck>`

### 0x002E — `MAPPA_DELAY_GAS_TEMP` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_DELAY_GAS_TEMP`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `46`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 2E 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 2E <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x002F — `RIF_DELAY_GAS_TEMP` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_DELAY_GAS_TEMP`

- **Classe:** `TAebVector`; **SerialCode decimal:** `47`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 2F 00 <ck>`

- **Escrita v2:** `37 2F 0B 00 <9 bytes LE> <ck>`

### 0x0031 — `ACTION_DIAGNOSI_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/ACTION_DIAGNOSI_LR`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `49`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 3, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 31 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 31 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x0032 — `GIRI_CUTOFF_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_CUTOFF_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `50`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 32 00 <ck>`

- **Escrita v2:** `13 32 00 <2 byte(s) LE> <ck>`

### 0x0032 — `GIRI_TEMPO_CUTOFF` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_TEMPO_CUTOFF`

- **Classe:** `TAebVector`; **SerialCode decimal:** `50`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 32 00 <ck>`

- **Escrita v2:** `35 32 00 <4 bytes LE> <ck>`

### 0x0033 — `SUB_CLIENT_CODE` (TSTREAMDATI)

- **Caminho:** `StreamDati/SUB_CLIENT_CODE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `51`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 33 00 <ck>`

- **Escrita v2:** `13 33 00 <2 byte(s) LE> <ck>`

### 0x0033 — `TEMPO_CUTOFF_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_CUTOFF_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `51`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 33 00 <ck>`

- **Escrita v2:** `13 33 00 <2 byte(s) LE> <ck>`

### 0x0034 — `TIPO_INIEZIONE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_INIEZIONE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `52`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 34 00 <ck>`

- **Escrita v2:** `12 34 00 <1 byte(s) LE> <ck>`

### 0x0035 — `IDENTIFICATIVO` (TSTREAMDATI)

- **Caminho:** `StreamDati/IDENTIFICATIVO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `53`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `30.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[30, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 35 00 <ck>`

- **Escrita v2:** `37 35 20 00 <30 bytes LE> <ck>`

### 0x0036 — `TEMPO_INIEZIONE_CONTINUA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_INIEZIONE_CONTINUA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `54`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 36 00 <ck>`

- **Escrita v2:** `12 36 00 <1 byte(s) LE> <ck>`

### 0x0037 — `TEMPI_PER_K` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPI_PER_K`

- **Classe:** `TAebVector`; **SerialCode decimal:** `55`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 37 00 <ck>`

- **Escrita v2:** `37 37 1A 00 <24 bytes LE> <ck>`

### 0x0038 — `CORRENTE_MANTENIMENTO` (TSTREAMDATI)

- **Caminho:** `StreamDati/CORRENTE_MANTENIMENTO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `56`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 38 00 <ck>`

- **Escrita v2:** `12 38 00 <1 byte(s) LE> <ck>`

### 0x0039 — `STATO_DIAGNOSI_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/STATO_DIAGNOSI_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `57`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 39 00 <ck>`

- **Escrita v2:** `36 39 00 <5 bytes LE> <ck>`

### 0x003A — `ABIL_DIAGNOSI_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/ABIL_DIAGNOSI_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `58`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 3A 00 <ck>`

- **Escrita v2:** `36 3A 00 <5 bytes LE> <ck>`

### 0x003B — `TEMPO_GAS` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_GAS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `59`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 3B 00 <ck>`

- **Escrita v2:** `13 3B 00 <2 byte(s) LE> <ck>`

### 0x003C — `TEMPO_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_BENZINA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `60`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 3C 00 <ck>`

- **Escrita v2:** `13 3C 00 <2 byte(s) LE> <ck>`

### 0x003D — `GIRI_PER_K` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_PER_K`

- **Classe:** `TAebVector`; **SerialCode decimal:** `61`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 3D 00 <ck>`

- **Escrita v2:** `37 3D 1A 00 <24 bytes LE> <ck>`

### 0x003E — `TEMPO_RITORNO_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_RITORNO_BENZINA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `62`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 3E 00 <ck>`

- **Escrita v2:** `12 3E 00 <1 byte(s) LE> <ck>`

### 0x0040 — `CODICE_CLIENTE` (TSTREAMDATI)

- **Caminho:** `StreamDati/CODICE_CLIENTE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `64`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 40 00 <ck>`

- **Escrita v2:** `12 40 00 <1 byte(s) LE> <ck>`

### 0x0041 — `CODICE_MODELLO` (TSTREAMDATI)

- **Caminho:** `StreamDati/CODICE_MODELLO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `65`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 41 00 <ck>`

- **Escrita v2:** `12 41 00 <1 byte(s) LE> <ck>`

### 0x0042 — `CODICE_PERSONALIZZAZIONE` (TSTREAMDATI)

- **Caminho:** `StreamDati/CODICE_PERSONALIZZAZIONE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `66`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 42 00 <ck>`

- **Escrita v2:** `12 42 00 <1 byte(s) LE> <ck>`

### 0x0046 — `SOGLIA_RICCO_FORZATO` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_RICCO_FORZATO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `70`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 46 00 <ck>`

- **Escrita v2:** `12 46 00 <1 byte(s) LE> <ck>`

### 0x0047 — `LIVELLO_EMUL_ALTO` (TSTREAMDATI)

- **Caminho:** `StreamDati/LIVELLO_EMUL_ALTO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `71`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 47 00 <ck>`

- **Escrita v2:** `12 47 00 <1 byte(s) LE> <ck>`

### 0x0048 — `LIVELLO_EMUL_BASSO` (TSTREAMDATI)

- **Caminho:** `StreamDati/LIVELLO_EMUL_BASSO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `72`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 48 00 <ck>`

- **Escrita v2:** `12 48 00 <1 byte(s) LE> <ck>`

### 0x0049 — `TEMPO_CORRENTE_CUTOFF` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_CORRENTE_CUTOFF`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `73`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 49 00 <ck>`

- **Escrita v2:** `13 49 00 <2 byte(s) LE> <ck>`

### 0x004A — `TEMPO_MAX_CORRENTE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_MAX_CORRENTE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `74`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 4A 00 <ck>`

- **Escrita v2:** `35 4A 00 <4 bytes LE> <ck>`

### 0x004B — `CILINDRATA` (TSTREAMDATI)

- **Caminho:** `StreamDati/CILINDRATA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `75`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 4B 00 <ck>`

- **Escrita v2:** `13 4B 00 <2 byte(s) LE> <ck>`

### 0x004C — `MINIMA_VERSIONE_INTERFACCIA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MINIMA_VERSIONE_INTERFACCIA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `76`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 4C 00 <ck>`

- **Escrita v2:** `13 4C 00 <2 byte(s) LE> <ck>`

### 0x004D — `DIAGNOSI_INJ_GAS_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/DIAGNOSI_INJ_GAS_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `77`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 4D 00 <ck>`

- **Escrita v2:** `12 4D 00 <1 byte(s) LE> <ck>`

### 0x004E — `AVVIAMENTI_EMERGENZA` (TSTREAMDATI)

- **Caminho:** `StreamDati/AVVIAMENTI_EMERGENZA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `78`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 4E 00 <ck>`

- **Escrita v2:** `12 4E 00 <1 byte(s) LE> <ck>`

### 0x004F — `PARAM_INJ` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_INJ`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `79`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 4F 00 <ck>`

- **Escrita v2:** `13 4F 00 <2 byte(s) LE> <ck>`

### 0x0051 — `TEMP_DIAGNOSI` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMP_DIAGNOSI`

- **Classe:** `TAebVector`; **SerialCode decimal:** `81`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 51 00 <ck>`

- **Escrita v2:** `35 51 00 <4 bytes LE> <ck>`

### 0x0052 — `TEMPO_CHIUSURA_INIETTORE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_CHIUSURA_INIETTORE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `82`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 52 00 <ck>`

- **Escrita v2:** `13 52 00 <2 byte(s) LE> <ck>`

### 0x0053 — `TEMPO_APERTURA_INIETTORE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_APERTURA_INIETTORE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `83`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 53 00 <ck>`

- **Escrita v2:** `13 53 00 <2 byte(s) LE> <ck>`

### 0x0054 — `MAP_K` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAP_K`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `84`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[13, 12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 54 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 54 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x0055 — `TEMPO_GAS_PARZIALE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_GAS_PARZIALE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `85`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 55 00 <ck>`

- **Escrita v2:** `13 55 00 <2 byte(s) LE> <ck>`

### 0x0056 — `TEMPI_SECONDI` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPI_SECONDI`

- **Classe:** `TAebVector`; **SerialCode decimal:** `86`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 56 00 <ck>`

- **Escrita v2:** `37 56 08 00 <6 bytes LE> <ck>`

### 0x0058 — `TEMPO_TAGLIANDI` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_TAGLIANDI`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `88`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 58 00 <ck>`

- **Escrita v2:** `13 58 00 <2 byte(s) LE> <ck>`

### 0x005B — `WARNING_VERSIONE_INTERFACCIA` (TSTREAMDATI)

- **Caminho:** `StreamDati/WARNING_VERSIONE_INTERFACCIA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `91`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 5B 00 <ck>`

- **Escrita v2:** `13 5B 00 <2 byte(s) LE> <ck>`

### 0x005C — `RIF_TEMP_GAS` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_TEMP_GAS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `92`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 5C 00 <ck>`

- **Escrita v2:** `37 5C 0C 00 <10 bytes LE> <ck>`

### 0x005C — `RIF_TEMP_RID_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_TEMP_RID_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `92`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 5C 00 <ck>`

- **Escrita v2:** `37 5C 0C 00 <10 bytes LE> <ck>`

### 0x005D — `COEFF_TEMP_GAS` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_TEMP_GAS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `93`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 5D 00 <ck>`

- **Escrita v2:** `37 5D 0B 00 <9 bytes LE> <ck>`

### 0x005D — `COEFF_TEMP_RID_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_TEMP_RID_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `93`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 5D 00 <ck>`

- **Escrita v2:** `37 5D 0B 00 <9 bytes LE> <ck>`

### 0x005E — `DIAGNOSI_INJ_BENZ_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/DIAGNOSI_INJ_BENZ_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `94`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 5E 00 <ck>`

- **Escrita v2:** `12 5E 00 <1 byte(s) LE> <ck>`

### 0x005F — `RIF_PRESS_COLL` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_PRESS_COLL`

- **Classe:** `TAebVector`; **SerialCode decimal:** `95`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `15.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[15, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 5F 00 <ck>`

- **Escrita v2:** `37 5F 20 00 <30 bytes LE> <ck>`

### 0x0060 — `COEFF_PRESS_COLL` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_PRESS_COLL`

- **Classe:** `TAebVector`; **SerialCode decimal:** `96`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `15.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[15, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 60 00 <ck>`

- **Escrita v2:** `37 60 20 00 <30 bytes LE> <ck>`

### 0x0061 — `TEMPO_DA_ERRORE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_DA_ERRORE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `97`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 61 00 <ck>`

- **Escrita v2:** `35 61 00 <4 bytes LE> <ck>`

### 0x0064 — `GIRI_SUP_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_SUP_BENZINA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `100`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 64 00 <ck>`

- **Escrita v2:** `13 64 00 <2 byte(s) LE> <ck>`

### 0x0067 — `MAP_DELAY_LAMBDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAP_DELAY_LAMBDA`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `103`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 67 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 67 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x0067 — `PRESS_RETROPASSAGGIO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_RETROPASSAGGIO_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `103`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 67 00 <ck>`

- **Escrita v2:** `37 67 0E 00 <12 bytes LE> <ck>`

### 0x0068 — `RIF_PRESS_ASS_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_PRESS_ASS_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `104`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `15.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[15, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 68 00 <ck>`

- **Escrita v2:** `37 68 11 00 <15 bytes LE> <ck>`

### 0x0068 — `TEMP_ACQUA_MONOFUEL` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMP_ACQUA_MONOFUEL`

- **Classe:** `TAebVector`; **SerialCode decimal:** `104`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 68 00 <ck>`

- **Escrita v2:** `33 68 00 <2 bytes LE> <ck>`

### 0x0069 — `COEFF_PRESS_ASS_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_PRESS_ASS_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `105`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `15.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[15, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 69 00 <ck>`

- **Escrita v2:** `37 69 20 00 <30 bytes LE> <ck>`

### 0x006A — `NUMERO_INJ_BENZINA_CUTOFF` (TSTREAMDATI)

- **Caminho:** `StreamDati/NUMERO_INJ_BENZINA_CUTOFF`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `106`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 6A 00 <ck>`

- **Escrita v2:** `12 6A 00 <1 byte(s) LE> <ck>`

### 0x006A — `SOGLIA_FLUSSO_SUBSONICO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_FLUSSO_SUBSONICO_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `106`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 6A 00 <ck>`

- **Escrita v2:** `12 6A 00 <1 byte(s) LE> <ck>`

### 0x006B — `RITARDO_GIRI_EMULAZIONE_HIGH` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_GIRI_EMULAZIONE_HIGH`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `107`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 6B 00 <ck>`

- **Escrita v2:** `12 6B 00 <1 byte(s) LE> <ck>`

### 0x006B — `TAGLIA_INIETTORI_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TAGLIA_INIETTORI_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `107`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 6B 00 <ck>`

- **Escrita v2:** `12 6B 00 <1 byte(s) LE> <ck>`

### 0x006C — `LITRI_SERBATOIO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/LITRI_SERBATOIO_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `108`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 6C 00 <ck>`

- **Escrita v2:** `12 6C 00 <1 byte(s) LE> <ck>`

### 0x006D — `TEMPO_SOVRAPPOSIZIONE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_SOVRAPPOSIZIONE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `109`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 6D 00 <ck>`

- **Escrita v2:** `12 6D 00 <1 byte(s) LE> <ck>`

### 0x006E — `TEMPERATURA_GAS_AVVIO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPERATURA_GAS_AVVIO_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `110`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 6E 00 <ck>`

- **Escrita v2:** `37 6E 0B 00 <9 bytes LE> <ck>`

### 0x006E — `TEMPO_CICCHETTO` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_CICCHETTO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `110`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 6E 00 <ck>`

- **Escrita v2:** `12 6E 00 <1 byte(s) LE> <ck>`

### 0x006F — `RIF_MAP_SONDA_LAMBDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_MAP_SONDA_LAMBDA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `111`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 6F 00 <ck>`

- **Escrita v2:** `37 6F 0A 00 <8 bytes LE> <ck>`

### 0x006F — `RITARDO_PASSAGGIO_GAS_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_PASSAGGIO_GAS_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `111`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 6F 00 <ck>`

- **Escrita v2:** `37 6F 0A 00 <8 bytes LE> <ck>`

### 0x0070 — `MAP_RIF_SONDA_LAMBDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAP_RIF_SONDA_LAMBDA`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `112`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 70 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 70 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x0070 — `RIF_GIRI_BENZINA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_GIRI_BENZINA_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `112`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 70 00 <ck>`

- **Escrita v2:** `37 70 12 00 <16 bytes LE> <ck>`

### 0x0071 — `ADATTA_PARAMETRI_K_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/ADATTA_PARAMETRI_K_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `113`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 71 00 <ck>`

- **Escrita v2:** `35 71 00 <4 bytes LE> <ck>`

### 0x0071 — `MAPPA_FILTRO_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_FILTRO_BENZINA`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `113`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 71 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 71 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x0072 — `MAP_BENZINA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAP_BENZINA_LR`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `114`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 72 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 72 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x0072 — `MAP_FILTRO_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAP_FILTRO_BENZINA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `114`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 72 00 <ck>`

- **Escrita v2:** `37 72 1A 00 <24 bytes LE> <ck>`

### 0x0073 — `RIF_MAP_BENZINA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_MAP_BENZINA_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `115`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 73 00 <ck>`

- **Escrita v2:** `37 73 12 00 <16 bytes LE> <ck>`

### 0x0073 — `SGANCIO_FILTRO_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/SGANCIO_FILTRO_BENZINA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `115`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 73 00 <ck>`

- **Escrita v2:** `37 73 0E 00 <12 bytes LE> <ck>`

### 0x0074 — `CORR_ARRICCHIMENTO` (TSTREAMDATI)

- **Caminho:** `StreamDati/CORR_ARRICCHIMENTO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `116`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 74 00 <ck>`

- **Escrita v2:** `12 74 00 <1 byte(s) LE> <ck>`

### 0x0074 — `TIPO_CONNESSIONE_OBD_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_CONNESSIONE_OBD_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `116`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 74 00 <ck>`

- **Escrita v2:** `12 74 00 <1 byte(s) LE> <ck>`

### 0x0075 — `TEMP_GAS_CAMBIO` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMP_GAS_CAMBIO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `117`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 75 00 <ck>`

- **Escrita v2:** `12 75 00 <1 byte(s) LE> <ck>`

### 0x0075 — `TEMP_RID_CAMBIO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMP_RID_CAMBIO_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `117`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 75 00 <ck>`

- **Escrita v2:** `12 75 00 <1 byte(s) LE> <ck>`

### 0x0076 — `IMPEDENZA_INIETTORI` (TSTREAMDATI)

- **Caminho:** `StreamDati/IMPEDENZA_INIETTORI`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `118`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 76 00 <ck>`

- **Escrita v2:** `12 76 00 <1 byte(s) LE> <ck>`

### 0x0077 — `VAL_PERC_HOLDING_CURRENT` (TSTREAMDATI)

- **Caminho:** `StreamDati/VAL_PERC_HOLDING_CURRENT`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `119`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 77 00 <ck>`

- **Escrita v2:** `12 77 00 <1 byte(s) LE> <ck>`

### 0x0078 — `MAP_ESTERNO` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAP_ESTERNO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `120`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `6.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 78 00 <ck>`

- **Escrita v2:** `37 78 0E 00 <12 bytes LE> <ck>`

### 0x0079 — `BASE_TEMPI_GLOBALE` (TSTREAMDATI)

- **Caminho:** `StreamDati/BASE_TEMPI_GLOBALE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `121`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 79 00 <ck>`

- **Escrita v2:** `13 79 00 <2 byte(s) LE> <ck>`

### 0x007A — `K_MAPPA_NEUTRO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/K_MAPPA_NEUTRO_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `122`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 7A 00 <ck>`

- **Escrita v2:** `12 7A 00 <1 byte(s) LE> <ck>`

### 0x007B — `RIF_PRESS_DIFF` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_PRESS_DIFF`

- **Classe:** `TAebVector`; **SerialCode decimal:** `123`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `15.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[15, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 7B 00 <ck>`

- **Escrita v2:** `37 7B 20 00 <30 bytes LE> <ck>`

### 0x007C — `COEFF_PRESS_DIFF` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_PRESS_DIFF`

- **Classe:** `TAebVector`; **SerialCode decimal:** `124`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `15.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[15, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 7C 00 <ck>`

- **Escrita v2:** `37 7C 20 00 <30 bytes LE> <ck>`

### 0x007D — `TEMPO_MORTO_INIETTORI_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_MORTO_INIETTORI_BENZINA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `125`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 7D 00 <ck>`

- **Escrita v2:** `13 7D 00 <2 byte(s) LE> <ck>`

### 0x007E — `TEMPO_MORTO_INIETTORI_GAS` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_MORTO_INIETTORI_GAS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `126`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 7E 00 <ck>`

- **Escrita v2:** `13 7E 00 <2 byte(s) LE> <ck>`

### 0x007F — `TEMPI_K_OPENLOOP` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPI_K_OPENLOOP`

- **Classe:** `TAebVector`; **SerialCode decimal:** `127`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 7F 00 <ck>`

- **Escrita v2:** `37 7F 1A 00 <24 bytes LE> <ck>`

### 0x0080 — `TEMPO_FUORI_STABILIZZATO` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_FUORI_STABILIZZATO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `128`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 80 00 <ck>`

- **Escrita v2:** `13 80 00 <2 byte(s) LE> <ck>`

### 0x0081 — `K_FILTRO` (TSTREAMDATI)

- **Caminho:** `StreamDati/K_FILTRO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `129`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 81 00 <ck>`

- **Escrita v2:** `34 81 00 <3 bytes LE> <ck>`

### 0x0082 — `RIF_SONDA_LAMBDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_SONDA_LAMBDA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `130`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 82 00 <ck>`

- **Escrita v2:** `37 82 0E 00 <12 bytes LE> <ck>`

### 0x0083 — `RIT_EMUL_RICCA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIT_EMUL_RICCA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `131`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 83 00 <ck>`

- **Escrita v2:** `37 83 1A 00 <24 bytes LE> <ck>`

### 0x0084 — `RIF_DELAY_LAMBDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_DELAY_LAMBDA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `132`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 84 00 <ck>`

- **Escrita v2:** `37 84 0A 00 <8 bytes LE> <ck>`

### 0x0085 — `CORRETTORE_INTEGRALE` (TSTREAMDATI)

- **Caminho:** `StreamDati/CORRETTORE_INTEGRALE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `133`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 85 00 <ck>`

- **Escrita v2:** `35 85 00 <4 bytes LE> <ck>`

### 0x0086 — `TIPO_SENSORE_TEMPERATURA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_SENSORE_TEMPERATURA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `134`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 86 00 <ck>`

- **Escrita v2:** `12 86 00 <1 byte(s) LE> <ck>`

### 0x0087 — `RITARDO_GIRI_EMULAZIONE` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_GIRI_EMULAZIONE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `135`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 87 00 <ck>`

- **Escrita v2:** `12 87 00 <1 byte(s) LE> <ck>`

### 0x0088 — `SMAGRIMENTO_RIENTRO_CUTOFF` (TSTREAMDATI)

- **Caminho:** `StreamDati/SMAGRIMENTO_RIENTRO_CUTOFF`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `136`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 88 00 <ck>`

- **Escrita v2:** `12 88 00 <1 byte(s) LE> <ck>`

### 0x0089 — `NUMERO_INIETTATE_SMAGRIMENTO` (TSTREAMDATI)

- **Caminho:** `StreamDati/NUMERO_INIETTATE_SMAGRIMENTO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `137`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 89 00 <ck>`

- **Escrita v2:** `12 89 00 <1 byte(s) LE> <ck>`

### 0x008A — `PARAMETRI_TEMP` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAMETRI_TEMP`

- **Classe:** `TAebVector`; **SerialCode decimal:** `138`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 8A 00 <ck>`

- **Escrita v2:** `36 8A 00 <5 bytes LE> <ck>`

### 0x008B — `ECU_TEMP` (TSTREAMDATI)

- **Caminho:** `StreamDati/ECU_TEMP`

- **Classe:** `TAebVector`; **SerialCode decimal:** `139`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `30.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[30, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 8B 00 <ck>`

- **Escrita v2:** `37 8B 20 00 <30 bytes LE> <ck>`

### 0x008C — `PARAM_MAP_ESTERNO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_MAP_ESTERNO_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `140`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 8C 00 <ck>`

- **Escrita v2:** `35 8C 00 <4 bytes LE> <ck>`

### 0x008D — `GIRI_INTERVENTO_K_FILTRO` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_INTERVENTO_K_FILTRO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `141`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 8D 00 <ck>`

- **Escrita v2:** `13 8D 00 <2 byte(s) LE> <ck>`

### 0x008F — `TINJ_3000RPM` (TSTREAMDATI)

- **Caminho:** `StreamDati/TINJ_3000RPM`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `143`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 8F 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 8F <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x0090 — `TEMP_AUTOTARATURA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMP_AUTOTARATURA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `144`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 90 00 <ck>`

- **Escrita v2:** `12 90 00 <1 byte(s) LE> <ck>`

### 0x0091 — `SCARTO_MINIMO_TARATURA` (TSTREAMDATI)

- **Caminho:** `StreamDati/SCARTO_MINIMO_TARATURA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `145`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 91 00 <ck>`

- **Escrita v2:** `35 91 00 <4 bytes LE> <ck>`

### 0x0092 — `T_INJ_BENZ_MAX_CAMBIO` (TSTREAMDATI)

- **Caminho:** `StreamDati/T_INJ_BENZ_MAX_CAMBIO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `146`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 92 00 <ck>`

- **Escrita v2:** `13 92 00 <2 byte(s) LE> <ck>`

### 0x0093 — `SPOSTAMENTO_TARATURA` (TSTREAMDATI)

- **Caminho:** `StreamDati/SPOSTAMENTO_TARATURA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `147`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 93 00 <ck>`

- **Escrita v2:** `13 93 00 <2 byte(s) LE> <ck>`

### 0x0094 — `TIPO_INIETTORE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_INIETTORE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `148`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 94 00 <ck>`

- **Escrita v2:** `33 94 00 <2 bytes LE> <ck>`

### 0x0095 — `MAPPA_CORR_TARATURA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_CORR_TARATURA`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `149`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A 95 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 95 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x0096 — `GIRI_AUTOTARATURA` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_AUTOTARATURA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `150`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 96 00 <ck>`

- **Escrita v2:** `13 96 00 <2 byte(s) LE> <ck>`

### 0x0097 — `PARAM_AUTOTARATURA` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_AUTOTARATURA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `151`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 97 00 <ck>`

- **Escrita v2:** `34 97 00 <3 bytes LE> <ck>`

### 0x0098 — `PRESS_BASSA_RETROPAS_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_BASSA_RETROPAS_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `152`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 98 00 <ck>`

- **Escrita v2:** `13 98 00 <2 byte(s) LE> <ck>`

### 0x0098 — `TINJ_FILTRO` (TSTREAMDATI)

- **Caminho:** `StreamDati/TINJ_FILTRO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `152`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 98 00 <ck>`

- **Escrita v2:** `37 98 12 00 <16 bytes LE> <ck>`

### 0x0099 — `TEST_WORD_ARRAY` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEST_WORD_ARRAY`

- **Classe:** `TAebVector`; **SerialCode decimal:** `153`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 99 00 <ck>`

- **Escrita v2:** `37 99 16 00 <20 bytes LE> <ck>`

### 0x009A — `TEST_TEMPO_ARRAY` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEST_TEMPO_ARRAY`

- **Classe:** `TAebVector`; **SerialCode decimal:** `154`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 9A 00 <ck>`

- **Escrita v2:** `37 9A 16 00 <20 bytes LE> <ck>`

### 0x009B — `TEMPI_EXTRAINIETTATE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPI_EXTRAINIETTATE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `155`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 9B 00 <ck>`

- **Escrita v2:** `37 9B 08 00 <6 bytes LE> <ck>`

### 0x009C — `TEMPO_MAX_EXTRAINJ_BENZ` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_MAX_EXTRAINJ_BENZ`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `156`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 9C 00 <ck>`

- **Escrita v2:** `13 9C 00 <2 byte(s) LE> <ck>`

### 0x009D — `TEMPO_MAX_INJ_BENZ_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_MAX_INJ_BENZ_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `157`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 9D 00 <ck>`

- **Escrita v2:** `13 9D 00 <2 byte(s) LE> <ck>`

### 0x009E — `CORRETTORE_BANCATA2` (TSTREAMDATI)

- **Caminho:** `StreamDati/CORRETTORE_BANCATA2`

- **Classe:** `TAebVector`; **SerialCode decimal:** `158`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 9E 00 <ck>`

- **Escrita v2:** `37 9E 0E 00 <12 bytes LE> <ck>`

### 0x009E — `TEMPERATURA_ACQUA_AVVIO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPERATURA_ACQUA_AVVIO_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `158`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 9E 00 <ck>`

- **Escrita v2:** `37 9E 0B 00 <9 bytes LE> <ck>`

### 0x009F — `RITARDO_PASSAGGIO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_PASSAGGIO_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `159`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 9F 00 <ck>`

- **Escrita v2:** `37 9F 0A 00 <8 bytes LE> <ck>`

### 0x00A0 — `SEQUENZA_INJ_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/SEQUENZA_INJ_LR`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `160`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A A0 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x A0 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00A0 — `TEMPI_PER_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPI_PER_BENZINA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `160`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 A0 00 <ck>`

- **Escrita v2:** `37 A0 0A 00 <8 bytes LE> <ck>`

### 0x00A1 — `GIRI_PER_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_PER_BENZINA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `161`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 A1 00 <ck>`

- **Escrita v2:** `35 A1 00 <4 bytes LE> <ck>`

### 0x00A1 — `SEQUENZA_INJ_BENZ_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/SEQUENZA_INJ_BENZ_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `161`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 A1 00 <ck>`

- **Escrita v2:** `37 A1 0A 00 <8 bytes LE> <ck>`

### 0x00A2 — `TEMPO_INIEZIONE_CONTINUA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_INIEZIONE_CONTINUA_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `162`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 A2 00 <ck>`

- **Escrita v2:** `12 A2 00 <1 byte(s) LE> <ck>`

### 0x00A3 — `INIETTATE_PER_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/INIETTATE_PER_BENZINA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `163`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 A3 00 <ck>`

- **Escrita v2:** `33 A3 00 <2 bytes LE> <ck>`

### 0x00A3 — `RIF_MAP_ANTICIPO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_MAP_ANTICIPO_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `163`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 A3 00 <ck>`

- **Escrita v2:** `36 A3 00 <5 bytes LE> <ck>`

### 0x00A4 — `RIF_GIRI_ANTICIPO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_GIRI_ANTICIPO_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `164`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 A4 00 <ck>`

- **Escrita v2:** `37 A4 12 00 <16 bytes LE> <ck>`

### 0x00A5 — `MAPPA_ANTICIPO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_ANTICIPO_LR`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `165`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A A5 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x A5 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00A7 — `TIPI_SONDA_LAMBDA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPI_SONDA_LAMBDA_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `167`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 A7 00 <ck>`

- **Escrita v2:** `12 A7 00 <1 byte(s) LE> <ck>`

### 0x00AA — `EMULAZIONE_POSTERIORE` (TSTREAMDATI)

- **Caminho:** `StreamDati/EMULAZIONE_POSTERIORE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `170`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 AA 00 <ck>`

- **Escrita v2:** `33 AA 00 <2 bytes LE> <ck>`

### 0x00AB — `RIF_TEMP_GAS_OFFSET_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_TEMP_GAS_OFFSET_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `171`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `16.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[16, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 AB 00 <ck>`

- **Escrita v2:** `37 AB 12 00 <16 bytes LE> <ck>`

### 0x00AB — `TIPI_SONDA_LAMBDA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPI_SONDA_LAMBDA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `171`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 AB 00 <ck>`

- **Escrita v2:** `12 AB 00 <1 byte(s) LE> <ck>`

### 0x00AC — `MASK_INIETTORI_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MASK_INIETTORI_BENZINA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `172`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 AC 00 <ck>`

- **Escrita v2:** `13 AC 00 <2 byte(s) LE> <ck>`

### 0x00AC — `TEMPO_MORTO_INIETTORI_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPO_MORTO_INIETTORI_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `172`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `16.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[16, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 AC 00 <ck>`

- **Escrita v2:** `37 AC 22 00 <32 bytes LE> <ck>`

### 0x00AD — `GIRI_ALTI_INTERVENTO_K_FILTRO_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_ALTI_INTERVENTO_K_FILTRO_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `173`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 AD 00 <ck>`

- **Escrita v2:** `13 AD 00 <2 byte(s) LE> <ck>`

### 0x00AE — `ClonedEcuRealFw0` (TSTREAMDATI)

- **Caminho:** `StreamDati/ClonedEcuRealFw0`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `174`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `0A AE 00 <index> <ck>`

- **Escrita v2:** `13 AE 00 <index> <1 byte(s) LE> <ck>`

### 0x00AE — `ClonedEcuRealFw1` (TSTREAMDATI)

- **Caminho:** `StreamDati/ClonedEcuRealFw1`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `174`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `0A AE 00 <index> <ck>`

- **Escrita v2:** `13 AE 00 <index> <1 byte(s) LE> <ck>`

### 0x00AE — `K_FILTRO_GIRI_ALTI_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/K_FILTRO_GIRI_ALTI_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `174`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 AE 00 <ck>`

- **Escrita v2:** `12 AE 00 <1 byte(s) LE> <ck>`

### 0x00AF — `CONTROL_CODE` (TSTREAMDATI)

- **Caminho:** `StreamDati/CONTROL_CODE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `175`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 AF 00 <ck>`

- **Escrita v2:** `37 AF 14 00 <18 bytes LE> <ck>`

### 0x00AF — `TEMPI_PER_BENZINA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPI_PER_BENZINA_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `175`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 AF 00 <ck>`

- **Escrita v2:** `37 AF 0A 00 <8 bytes LE> <ck>`

### 0x00B0 — `GIRI_PER_BENZINA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_PER_BENZINA_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `176`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 B0 00 <ck>`

- **Escrita v2:** `35 B0 00 <4 bytes LE> <ck>`

### 0x00B0 — `LAMBDA_OFFSET` (TSTREAMDATI)

- **Caminho:** `StreamDati/LAMBDA_OFFSET`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `176`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 B0 00 <ck>`

- **Escrita v2:** `12 B0 00 <1 byte(s) LE> <ck>`

### 0x00B1 — `GIRI_SUP_BENZINA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/GIRI_SUP_BENZINA_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `177`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 B1 00 <ck>`

- **Escrita v2:** `13 B1 00 <2 byte(s) LE> <ck>`

### 0x00B2 — `MASK_INIETTORI_BENZINA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/MASK_INIETTORI_BENZINA_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `178`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 B2 00 <ck>`

- **Escrita v2:** `13 B2 00 <2 byte(s) LE> <ck>`

### 0x00B2 — `RITARDO_CAMBIO_HIGH` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_CAMBIO_HIGH`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `178`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 B2 00 <ck>`

- **Escrita v2:** `12 B2 00 <1 byte(s) LE> <ck>`

### 0x00B3 — `CHANGE_OVER` (TSTREAMDATI)

- **Caminho:** `StreamDati/CHANGE_OVER`

- **Classe:** `TAebVector`; **SerialCode decimal:** `179`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 B3 00 <ck>`

- **Escrita v2:** `35 B3 00 <4 bytes LE> <ck>`

### 0x00B4 — `SMAGRIMENTO_MIN` (TSTREAMDATI)

- **Caminho:** `StreamDati/SMAGRIMENTO_MIN`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `180`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 B4 00 <ck>`

- **Escrita v2:** `12 B4 00 <1 byte(s) LE> <ck>`

### 0x00B5 — `TIPO_CARBURANTE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_CARBURANTE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `181`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 B5 00 <ck>`

- **Escrita v2:** `12 B5 00 <1 byte(s) LE> <ck>`

### 0x00B6 — `SMP_CALIBRATO` (TSTREAMDATI)

- **Caminho:** `StreamDati/SMP_CALIBRATO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `182`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 B6 00 <ck>`

- **Escrita v2:** `13 B6 00 <2 byte(s) LE> <ck>`

### 0x00B9 — `CONFIGURA_ADATTA` (TSTREAMDATI)

- **Caminho:** `StreamDati/CONFIGURA_ADATTA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `185`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 B9 00 <ck>`

- **Escrita v2:** `33 B9 00 <2 bytes LE> <ck>`

### 0x00BB — `CORRETTORE_BANCATA2_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/CORRETTORE_BANCATA2_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `187`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 BB 00 <ck>`

- **Escrita v2:** `12 BB 00 <1 byte(s) LE> <ck>`

### 0x00BB — `TIPO_CONNESSIONE_OBD` (TSTREAMDATI)

- **Caminho:** `StreamDati/TIPO_CONNESSIONE_OBD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `187`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 BB 00 <ck>`

- **Escrita v2:** `12 BB 00 <1 byte(s) LE> <ck>`

### 0x00BC — `K_MAPPA_NEUTRO` (TSTREAMDATI)

- **Caminho:** `StreamDati/K_MAPPA_NEUTRO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `188`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 BC 00 <ck>`

- **Escrita v2:** `12 BC 00 <1 byte(s) LE> <ck>`

### 0x00BD — `CONFIGURA_ADATTA_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/CONFIGURA_ADATTA_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `189`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 BD 00 <ck>`

- **Escrita v2:** `33 BD 00 <2 bytes LE> <ck>`

### 0x00BD — `PRESS_RETROPASSAGGIO` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_RETROPASSAGGIO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `189`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 BD 00 <ck>`

- **Escrita v2:** `37 BD 1A 00 <24 bytes LE> <ck>`

### 0x00BE — `IDENT_OBD` (TSTREAMDATI)

- **Caminho:** `StreamDati/IDENT_OBD`

- **Classe:** `TAebVector`; **SerialCode decimal:** `190`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `16.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[16, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 BE 00 <ck>`

- **Escrita v2:** `37 BE 12 00 <16 bytes LE> <ck>`

### 0x00BF — `SPLIT_FUEL` (TSTREAMDATI)

- **Caminho:** `StreamDati/SPLIT_FUEL`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `191`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 BF 00 <ck>`

- **Escrita v2:** `12 BF 00 <1 byte(s) LE> <ck>`

### 0x00C0 — `FLAG_CONF2` (TSTREAMDATI)

- **Caminho:** `StreamDati/FLAG_CONF2`

- **Classe:** `TAebVector`; **SerialCode decimal:** `192`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 C0 00 <ck>`

- **Escrita v2:** `35 C0 00 <4 bytes LE> <ck>`

### 0x00C1 — `FLAG_CONF2_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/FLAG_CONF2_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `193`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 C1 00 <ck>`

- **Escrita v2:** `35 C1 00 <4 bytes LE> <ck>`

### 0x00C2 — `MASK_FUNCTION` (TSTREAMDATI)

- **Caminho:** `StreamDati/MASK_FUNCTION`

- **Classe:** `TAebVector`; **SerialCode decimal:** `194`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `30.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[30, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 C2 00 <ck>`

- **Escrita v2:** `37 C2 20 00 <30 bytes LE> <ck>`

### 0x00C3 — `TEMP_GAS_CALDO` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMP_GAS_CALDO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `195`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 C3 00 <ck>`

- **Escrita v2:** `12 C3 00 <1 byte(s) LE> <ck>`

### 0x00C4 — `RIF_PRESS_SPLIT_FUEL` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_PRESS_SPLIT_FUEL`

- **Classe:** `TAebVector`; **SerialCode decimal:** `196`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 C4 00 <ck>`

- **Escrita v2:** `37 C4 0C 00 <10 bytes LE> <ck>`

### 0x00C5 — `COEFF_PRESS_SPLIT_FUEL` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_PRESS_SPLIT_FUEL`

- **Classe:** `TAebVector`; **SerialCode decimal:** `197`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 C5 00 <ck>`

- **Escrita v2:** `37 C5 0C 00 <10 bytes LE> <ck>`

### 0x00C6 — `K_FACTOR_PARAM` (TSTREAMDATI)

- **Caminho:** `StreamDati/K_FACTOR_PARAM`

- **Classe:** `TAebVector`; **SerialCode decimal:** `198`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 C6 00 <ck>`

- **Escrita v2:** `37 C6 0A 00 <8 bytes LE> <ck>`

### 0x00C8 — `RPM_FOR_SPLIT_FUEL` (TSTREAMDATI)

- **Caminho:** `StreamDati/RPM_FOR_SPLIT_FUEL`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `200`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 C8 00 <ck>`

- **Escrita v2:** `13 C8 00 <2 byte(s) LE> <ck>`

### 0x00C9 — `OVER_PRESSURE_DIAGNOSYS` (TSTREAMDATI)

- **Caminho:** `StreamDati/OVER_PRESSURE_DIAGNOSYS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `201`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 C9 00 <ck>`

- **Escrita v2:** `13 C9 00 <2 byte(s) LE> <ck>`

### 0x00CB — `PETROL_MAP` (TSTREAMDATI)

- **Caminho:** `StreamDati/PETROL_MAP`

- **Classe:** `TAebVector`; **SerialCode decimal:** `203`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 CB 00 <ck>`

- **Escrita v2:** `37 CB 26 00 <36 bytes LE> <ck>`

### 0x00CC — `PETROL_RPM_MAP_INJ` (TSTREAMDATI)

- **Caminho:** `StreamDati/PETROL_RPM_MAP_INJ`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `204`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A CC 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x CC <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00CD — `PETROL_RPM_MAP_NUM` (TSTREAMDATI)

- **Caminho:** `StreamDati/PETROL_RPM_MAP_NUM`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `205`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A CD 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x CD <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00CE — `PETROL_RPM` (TSTREAMDATI)

- **Caminho:** `StreamDati/PETROL_RPM`

- **Classe:** `TAebVector`; **SerialCode decimal:** `206`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 CE 00 <ck>`

- **Escrita v2:** `37 CE 1A 00 <24 bytes LE> <ck>`

### 0x00CF — `RITARDO_ATTIVAZIONE_INIETTORI` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_ATTIVAZIONE_INIETTORI`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `207`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 CF 00 <ck>`

- **Escrita v2:** `13 CF 00 <2 byte(s) LE> <ck>`

### 0x00D0 — `MAPPA_CONTRIBUTI_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_CONTRIBUTI_BENZINA`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `208`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A D0 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x D0 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00D1 — `MAPPA_TRANSITORI_POSITIVI` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_TRANSITORI_POSITIVI`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `209`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A D1 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x D1 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00D2 — `MAPPA_TRANSITORI_NEGATIVI` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_TRANSITORI_NEGATIVI`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `210`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A D2 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x D2 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00D3 — `MAPPA_CORREZIONI_ACCELERAZIONE` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_CORREZIONI_ACCELERAZIONE`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `211`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A D3 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x D3 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00D4 — `MAPPA_CORREZIONI_DECELERAZIONE` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_CORREZIONI_DECELERAZIONE`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `212`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A D4 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x D4 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00D5 — `NUMERO_PARTENZE_EMERGENZA` (TSTREAMDATI)

- **Caminho:** `StreamDati/NUMERO_PARTENZE_EMERGENZA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `213`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 D5 00 <ck>`

- **Escrita v2:** `12 D5 00 <1 byte(s) LE> <ck>`

### 0x00D6 — `SOGLIA_LETTURA_GIRI_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_LETTURA_GIRI_LR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `214`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 D6 00 <ck>`

- **Escrita v2:** `12 D6 00 <1 byte(s) LE> <ck>`

### 0x00D7 — `MAPPA_RIF_TRANSITORI_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_RIF_TRANSITORI_BENZINA`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `215`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A D7 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x D7 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00D8 — `MAPPA_DIFFERENZE_K` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_DIFFERENZE_K`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `216`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[13, 12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A D8 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x D8 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00D9 — `AUTO_CALIBR_BYTE_ARRAY` (TSTREAMDATI)

- **Caminho:** `StreamDati/AUTO_CALIBR_BYTE_ARRAY`

- **Classe:** `TAebVector`; **SerialCode decimal:** `217`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 D9 00 <ck>`

- **Escrita v2:** `37 D9 0C 00 <10 bytes LE> <ck>`

### 0x00DA — `AUTO_CALIBR_WORD_ARRAY` (TSTREAMDATI)

- **Caminho:** `StreamDati/AUTO_CALIBR_WORD_ARRAY`

- **Classe:** `TAebVector`; **SerialCode decimal:** `218`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 DA 00 <ck>`

- **Escrita v2:** `37 DA 16 00 <20 bytes LE> <ck>`

### 0x00DB — `ADVANCED_PARAM_INJ` (TSTREAMDATI)

- **Caminho:** `StreamDati/ADVANCED_PARAM_INJ`

- **Classe:** `TAebVector`; **SerialCode decimal:** `219`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `6.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 DB 00 <ck>`

- **Escrita v2:** `37 DB 0E 00 <12 bytes LE> <ck>`

### 0x00DC — `TEMPERATURA_ACQUA_AVVIO` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPERATURA_ACQUA_AVVIO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `220`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 DC 00 <ck>`

- **Escrita v2:** `37 DC 0B 00 <9 bytes LE> <ck>`

### 0x00DD — `RITARDO_PASSAGGIO` (TSTREAMDATI)

- **Caminho:** `StreamDati/RITARDO_PASSAGGIO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `221`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 DD 00 <ck>`

- **Escrita v2:** `37 DD 0A 00 <8 bytes LE> <ck>`

### 0x00DE — `SOGLIA_FLUSSO_SUBSONICO` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_FLUSSO_SUBSONICO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `222`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 DE 00 <ck>`

- **Escrita v2:** `12 DE 00 <1 byte(s) LE> <ck>`

### 0x00DF — `RIF_PRESS_ASS` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIF_PRESS_ASS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `223`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `15.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[15, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 DF 00 <ck>`

- **Escrita v2:** `37 DF 11 00 <15 bytes LE> <ck>`

### 0x00E0 — `COEFF_PRESS_ASS` (TSTREAMDATI)

- **Caminho:** `StreamDati/COEFF_PRESS_ASS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `224`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `15.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[15, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E0 00 <ck>`

- **Escrita v2:** `37 E0 20 00 <30 bytes LE> <ck>`

### 0x00E1 — `TAGLIA_INIETTORE` (TSTREAMDATI)

- **Caminho:** `StreamDati/TAGLIA_INIETTORE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `225`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 E1 00 <ck>`

- **Escrita v2:** `12 E1 00 <1 byte(s) LE> <ck>`

### 0x00E2 — `CHANGE_OVER_CILYNDER_DELAY` (TSTREAMDATI)

- **Caminho:** `StreamDati/CHANGE_OVER_CILYNDER_DELAY`

- **Classe:** `TAebVector`; **SerialCode decimal:** `226`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E2 00 <ck>`

- **Escrita v2:** `37 E2 0A 00 <8 bytes LE> <ck>`

### 0x00E3 — `FREST_PARAMETER_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/FREST_PARAMETER_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `227`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `6.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E3 00 <ck>`

- **Escrita v2:** `37 E3 0E 00 <12 bytes LE> <ck>`

### 0x00E3 — `SERVICE_DATA` (TSTREAMDATI)

- **Caminho:** `StreamDati/SERVICE_DATA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `227`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `25.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E3 00 <ck>`

- **Escrita v2:** `37 E3 1B 00 <25 bytes LE> <ck>`

### 0x00E4 — `FREST_BREAKPOINT_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/FREST_BREAKPOINT_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `228`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `6.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E4 00 <ck>`

- **Escrita v2:** `37 E4 0E 00 <12 bytes LE> <ck>`

### 0x00E5 — `FREST_COEFFICIENT_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/FREST_COEFFICIENT_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `229`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `6.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E5 00 <ck>`

- **Escrita v2:** `37 E5 0E 00 <12 bytes LE> <ck>`

### 0x00E6 — `SOGLIA_CORRETTORE_GAS` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_CORRETTORE_GAS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `230`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 E6 00 <ck>`

- **Escrita v2:** `12 E6 00 <1 byte(s) LE> <ck>`

### 0x00E7 — `ADVANCED_TEMP_RID` (TSTREAMDATI)

- **Caminho:** `StreamDati/ADVANCED_TEMP_RID`

- **Classe:** `TAebVector`; **SerialCode decimal:** `231`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E7 00 <ck>`

- **Escrita v2:** `35 E7 00 <4 bytes LE> <ck>`

### 0x00E8 — `ADVANCED_PRESS_BACK` (TSTREAMDATI)

- **Caminho:** `StreamDati/ADVANCED_PRESS_BACK`

- **Classe:** `TAebVector`; **SerialCode decimal:** `232`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E8 00 <ck>`

- **Escrita v2:** `35 E8 00 <4 bytes LE> <ck>`

### 0x00E9 — `SOGLIE_SESTANTI` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIE_SESTANTI`

- **Classe:** `TAebVector`; **SerialCode decimal:** `233`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 E9 00 <ck>`

- **Escrita v2:** `37 E9 0C 00 <10 bytes LE> <ck>`

### 0x00EA — `RIGHE_MAPPAK_CALIBRATE` (TSTREAMDATI)

- **Caminho:** `StreamDati/RIGHE_MAPPAK_CALIBRATE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `234`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 EA 00 <ck>`

- **Escrita v2:** `37 EA 0E 00 <12 bytes LE> <ck>`

### 0x00EB — `MAPPA_ADATTA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAPPA_ADATTA`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `235`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A EB 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x EB <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00EC — `SWITCH_TO_PETROL_PARAM_LR` (TSTREAMDATI)

- **Caminho:** `StreamDati/SWITCH_TO_PETROL_PARAM_LR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `236`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `9.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 EC 00 <ck>`

- **Escrita v2:** `37 EC 14 00 <18 bytes LE> <ck>`

### 0x00ED — `PARAMETRI_TAGLIANDI` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAMETRI_TAGLIANDI`

- **Classe:** `TAebVector`; **SerialCode decimal:** `237`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 ED 00 <ck>`

- **Escrita v2:** `34 ED 00 <3 bytes LE> <ck>`

### 0x00EE — `TEMPI_ANTICIPI_EV` (TSTREAMDATI)

- **Caminho:** `StreamDati/TEMPI_ANTICIPI_EV`

- **Classe:** `TAebVector`; **SerialCode decimal:** `238`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 EE 00 <ck>`

- **Escrita v2:** `33 EE 00 <2 bytes LE> <ck>`

### 0x00EF — `SOGLIA_GIRI_ADATTATIVITA_WORD` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_GIRI_ADATTATIVITA_WORD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `239`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 EF 00 <ck>`

- **Escrita v2:** `13 EF 00 <2 byte(s) LE> <ck>`

### 0x00F0 — `MAP_FLEX` (TSTREAMDATI)

- **Caminho:** `StreamDati/MAP_FLEX`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `240`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[13, 12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `2A F0 00 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x F0 <len?> 00 <row> <row-data> <ck> (SetVector indexado)`

### 0x00F1 — `ADV_PARAM_INJ` (TSTREAMDATI)

- **Caminho:** `StreamDati/ADV_PARAM_INJ`

- **Classe:** `TAebVector`; **SerialCode decimal:** `241`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `12.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 F1 00 <ck>`

- **Escrita v2:** `37 F1 1A 00 <24 bytes LE> <ck>`

### 0x00F2 — `ADV_OFFSET_INJ_PETROL` (TSTRATEGIATEMPIMORTIDM)

- **Caminho:** `StrategiaTempiMortiDM/ADV_OFFSET_INJ_PETROL`

- **Classe:** `TAebVector`; **SerialCode decimal:** `242`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`Iniezione`, key=`Prt0010`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 F2 00 <ck>`

- **Escrita v2:** `37 F2 0C 00 <10 bytes LE> <ck>`

### 0x00F3 — `ADV_OFFSET_INJ_GAS` (TSTRATEGIATEMPIMORTIDM)

- **Caminho:** `StrategiaTempiMortiDM/ADV_OFFSET_INJ_GAS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `243`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`Iniezione`, key=`Prt0011`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 F3 00 <ck>`

- **Escrita v2:** `37 F3 0C 00 <10 bytes LE> <ck>`

### 0x00F8 — `FLASH_LUBE_PARAMETER` (TSTREAMDATI)

- **Caminho:** `StreamDati/FLASH_LUBE_PARAMETER`

- **Classe:** `TAebVector`; **SerialCode decimal:** `248`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 F8 00 <ck>`

- **Escrita v2:** `37 F8 0A 00 <8 bytes LE> <ck>`

### 0x00F9 — `NUM_DENTI_ALBERO_CAMME` (TSTREAMDATI)

- **Caminho:** `StreamDati/NUM_DENTI_ALBERO_CAMME`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `249`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 F9 00 <ck>`

- **Escrita v2:** `12 F9 00 <1 byte(s) LE> <ck>`

### 0x00FA — `FLAG_CONF3` (TSTREAMDATI)

- **Caminho:** `StreamDati/FLAG_CONF3`

- **Classe:** `TAebVector`; **SerialCode decimal:** `250`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `2.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[2, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 FA 00 <ck>`

- **Escrita v2:** `35 FA 00 <4 bytes LE> <ck>`

### 0x010C — `TAGLIO_POMPA_BENZINA` (TSTREAMDATI)

- **Caminho:** `StreamDati/TAGLIO_POMPA_BENZINA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `268`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 0C 01 <ck>`

- **Escrita v2:** `37 0C 0C 01 <10 bytes LE> <ck>`

### 0x010D — `OBD_PARAMETER_PID` (TSTREAMDATI)

- **Caminho:** `StreamDati/OBD_PARAMETER_PID`

- **Classe:** `TAebVector`; **SerialCode decimal:** `269`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 0D 01 <ck>`

- **Escrita v2:** `37 0D 0A 01 <8 bytes LE> <ck>`

### 0x0114 — `LO_PASS_FILT_CON_FAST` (TSTREAMDATI)

- **Caminho:** `StreamDati/LO_PASS_FILT_CON_FAST`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `276`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 32768.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+32768); x=(0-32768*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `0.0001`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`1.9999`

- **Default:** `1.0`

- **INI/arquivo:** section=`Agaslev`, key=`VectAgaslevKFilter`; connection=`AebConnection`

- **Leitura v2:** `0A 14 01 <index> <ck>`

- **Escrita v2:** `14 14 01 <index> <2 byte(s) LE> <ck>`

### 0x0114 — `LO_PASS_FILT_CON_SLOW` (TSTREAMDATI)

- **Caminho:** `StreamDati/LO_PASS_FILT_CON_SLOW`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `276`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 32768.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+32768); x=(0-32768*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `0.0001`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`1.9999`

- **Default:** `0.015`

- **INI/arquivo:** section=`Agaslev`, key=`VectAgaslevKFilter`; connection=`AebConnection`

- **Leitura v2:** `0A 14 01 <index> <ck>`

- **Escrita v2:** `14 14 01 <index> <2 byte(s) LE> <ck>`

### 0x0123 — `PRESS_INSUL_DIAG_MIN_TANK_LVL_THD` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_INSUL_DIAG_MIN_TANK_LVL_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `291`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 256.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+256); x=(0-256*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`-128.0`, max=`127.996`

- **Default:** `20.0`

- **INI/arquivo:** section=`Dhlp`, key=`VectDhlpPerc`; connection=`AebConnection`

- **Leitura v2:** `0A 23 01 <index> <ck>`

- **Escrita v2:** `14 23 01 <index> <2 byte(s) LE> <ck>`

### 0x0124 — `LO_PRESS_INSUL_DIAG_FALL_THD` (TSTREAMDATI)

- **Caminho:** `StreamDati/LO_PRESS_INSUL_DIAG_FALL_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `292`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`-32.0`, max=`31.999`

- **Default:** `0.15`

- **INI/arquivo:** section=`Dhlp`, key=`VectDhlpLoPress`; connection=`AebConnection`

- **Leitura v2:** `0A 24 01 <index> <ck>`

- **Escrita v2:** `14 24 01 <index> <2 byte(s) LE> <ck>`

### 0x0125 — `PRESS_INSUL_DIAG_AFT_CRK_DLY` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_INSUL_DIAG_AFT_CRK_DLY`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `293`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `—`; **row_index:** `2.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`63.999`

- **Default:** `5.0`

- **INI/arquivo:** section=`Dhlp`, key=`VectDhlpTime`; connection=`AebConnection`

- **Leitura v2:** `0A 25 01 <index> <ck>`

- **Escrita v2:** `14 25 01 <index> <2 byte(s) LE> <ck>`

### 0x0125 — `PRESS_INSUL_DIAG_PRESS_ZNT` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_INSUL_DIAG_PRESS_ZNT`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `293`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `—`; **row_index:** `3.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`63.999`

- **Default:** `1.0`

- **INI/arquivo:** section=`Dhlp`, key=`VectDhlpTime`; connection=`AebConnection`

- **Leitura v2:** `0A 25 01 <index> <ck>`

- **Escrita v2:** `14 25 01 <index> <2 byte(s) LE> <ck>`

### 0x0125 — `PRESS_INSUL_DIAG_PRESS_ZNT_OUT` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_INSUL_DIAG_PRESS_ZNT_OUT`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `293`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `—`; **row_index:** `4.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`63.999`

- **Default:** `5.0`

- **INI/arquivo:** section=`Dhlp`, key=`VectDhlpTime`; connection=`AebConnection`

- **Leitura v2:** `0A 25 01 <index> <ck>`

- **Escrita v2:** `14 25 01 <index> <2 byte(s) LE> <ck>`

### 0x0127 — `PRESS_INSUL_DIAG_WAT_TEMP_HI_THD` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_INSUL_DIAG_WAT_TEMP_HI_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `295`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`-128.0`, max=`127.0`

- **Default:** `20.0`

- **INI/arquivo:** section=`Dhlp`, key=`VectDhlpTempC`; connection=`AebConnection`

- **Leitura v2:** `0A 27 01 <index> <ck>`

- **Escrita v2:** `13 27 01 <index> <1 byte(s) LE> <ck>`

### 0x0127 — `PRESS_INSUL_DIAG_WAT_TEMP_LO_THD` (TSTREAMDATI)

- **Caminho:** `StreamDati/PRESS_INSUL_DIAG_WAT_TEMP_LO_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `295`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`-128.0`, max=`127.0`

- **Default:** `-128.0`

- **INI/arquivo:** section=`Dhlp`, key=`VectDhlpTempC`; connection=`AebConnection`

- **Leitura v2:** `0A 27 01 <index> <ck>`

- **Escrita v2:** `13 27 01 <index> <1 byte(s) LE> <ck>`

### 0x012B — `PARAM_PROGRESS_0` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_PROGRESS_0`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `299`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `4.0`

- **INI/arquivo:** section=`Cambio`, key=`CambioConSovrapp`; connection=`AebConnection`

- **Leitura v2:** `0A 2B 01 <index> <ck>`

- **Escrita v2:** `14 2B 01 <index> <2 byte(s) LE> <ck>`

### 0x012B — `PARAM_PROGRESS_1` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_PROGRESS_1`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `299`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `500.0`

- **INI/arquivo:** section=`Cambio`, key=`CambioConSovrapp`; connection=`AebConnection`

- **Leitura v2:** `0A 2B 01 <index> <ck>`

- **Escrita v2:** `14 2B 01 <index> <2 byte(s) LE> <ck>`

### 0x012B — `PARAM_PROGRESS_2` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_PROGRESS_2`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `299`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `2.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `100.0`

- **INI/arquivo:** section=`Cambio`, key=`CambioConSovrapp`; connection=`AebConnection`

- **Leitura v2:** `0A 2B 01 <index> <ck>`

- **Escrita v2:** `14 2B 01 <index> <2 byte(s) LE> <ck>`

### 0x012B — `PARAM_PROGRESS_3` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_PROGRESS_3`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `299`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `3.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `100.0`

- **INI/arquivo:** section=`Cambio`, key=`CambioConSovrapp`; connection=`AebConnection`

- **Leitura v2:** `0A 2B 01 <index> <ck>`

- **Escrita v2:** `14 2B 01 <index> <2 byte(s) LE> <ck>`

### 0x012C — `ISTERESI_RIACCENSIONE` (TSTREAMDATI)

- **Caminho:** `StreamDati/ISTERESI_RIACCENSIONE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `300`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `3.0`

- **INI/arquivo:** section=`RiaccLed`, key=`VectRiaccLed`; connection=`AebConnection`

- **Leitura v2:** `0A 2C 01 <index> <ck>`

- **Escrita v2:** `13 2C 01 <index> <1 byte(s) LE> <ck>`

### 0x012C — `SOGLIA_LED_1` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_LED_1`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `300`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `12.0`

- **INI/arquivo:** section=`RiaccLed`, key=`VectRiaccLed`; connection=`AebConnection`

- **Leitura v2:** `0A 2C 01 <index> <ck>`

- **Escrita v2:** `13 2C 01 <index> <1 byte(s) LE> <ck>`

### 0x012C — `SOGLIA_LED_2` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_LED_2`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `300`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `2.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `37.0`

- **INI/arquivo:** section=`RiaccLed`, key=`VectRiaccLed`; connection=`AebConnection`

- **Leitura v2:** `0A 2C 01 <index> <ck>`

- **Escrita v2:** `13 2C 01 <index> <1 byte(s) LE> <ck>`

### 0x012C — `SOGLIA_LED_3` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_LED_3`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `300`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `3.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `62.0`

- **INI/arquivo:** section=`RiaccLed`, key=`VectRiaccLed`; connection=`AebConnection`

- **Leitura v2:** `0A 2C 01 <index> <ck>`

- **Escrita v2:** `13 2C 01 <index> <1 byte(s) LE> <ck>`

### 0x012C — `SOGLIA_LED_4` (TSTREAMDATI)

- **Caminho:** `StreamDati/SOGLIA_LED_4`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `300`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `4.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `87.0`

- **INI/arquivo:** section=`RiaccLed`, key=`VectRiaccLed`; connection=`AebConnection`

- **Leitura v2:** `0A 2C 01 <index> <ck>`

- **Escrita v2:** `13 2C 01 <index> <1 byte(s) LE> <ck>`

### 0x012D — `VH34_PARAM_INJ` (TSTREAMDATI)

- **Caminho:** `StreamDati/VH34_PARAM_INJ`

- **Classe:** `TAebVector`; **SerialCode decimal:** `301`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `20.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[20, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 2D 01 <ck>`

- **Escrita v2:** `37 2D 16 01 <20 bytes LE> <ck>`

### 0x012F — `ANTICIPO_INTERRUZIONE_WARMUP` (TSTREAMDATI)

- **Caminho:** `StreamDati/ANTICIPO_INTERRUZIONE_WARMUP`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `303`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`5.0`, max=`15.0`

- **Default:** `15.0`

- **INI/arquivo:** section=`Dhlp`, key=`ParametriVari`; connection=`AebConnection`

- **Leitura v2:** `0A 2F 01 <index> <ck>`

- **Escrita v2:** `13 2F 01 <index> <1 byte(s) LE> <ck>`

### 0x012F — `DELTA_AD_PER_WARMUP` (TSTREAMDATI)

- **Caminho:** `StreamDati/DELTA_AD_PER_WARMUP`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `303`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `5.0`

- **INI/arquivo:** section=`Dhlp`, key=`ParametriVari`; connection=`AebConnection`

- **Leitura v2:** `0A 2F 01 <index> <ck>`

- **Escrita v2:** `13 2F 01 <index> <1 byte(s) LE> <ck>`

### 0x012F — `DELTA_T_RAIL_BLOCCO_DHLP` (TSTREAMDATI)

- **Caminho:** `StreamDati/DELTA_T_RAIL_BLOCCO_DHLP`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `303`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `2.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`2.0`, max=`20.0`

- **Default:** `3.0`

- **INI/arquivo:** section=`Dhlp`, key=`ParametriVari`; connection=`AebConnection`

- **Leitura v2:** `0A 2F 01 <index> <ck>`

- **Escrita v2:** `13 2F 01 <index> <1 byte(s) LE> <ck>`

### 0x0132 — `WARMUP_PARAM_INJ` (TSTREAMDATI)

- **Caminho:** `StreamDati/WARMUP_PARAM_INJ`

- **Classe:** `TAebVector`; **SerialCode decimal:** `306`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `8.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 32 01 <ck>`

- **Escrita v2:** `37 32 0A 01 <8 bytes LE> <ck>`

### 0x0133 — `ANTI_STALLO` (TSTREAMDATI)

- **Caminho:** `StreamDati/ANTI_STALLO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `307`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 1600.0, 100.0, 1500.0, 2.0, 20.0]`

- **INI/arquivo:** section=`AntiStallo`, key=`Param`; connection=`AebConnection`

- **Leitura v2:** `29 33 01 <ck>`

- **Escrita v2:** `37 33 0C 01 <10 bytes LE> <ck>`

### 0x0134 — `PARAM_PROGRESSIONI` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_PROGRESSIONI`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `308`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 3, 0.0, 4.0, 500.0, 20.0, 4.0, 500.0, 20.0, 4.0, 500.0, 25.0, 4.0, 500.0]`

- **INI/arquivo:** section=`ProgressParam`, key=`Value`; connection=`AebConnection`

- **Leitura v2:** `2A 34 01 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 34 <len?> 01 <row> <row-data> <ck> (SetVector indexado)`

### 0x0138 — `PARAM_VARI` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAM_VARI`

- **Classe:** `TAebVector`; **SerialCode decimal:** `312`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 800.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`ParamVari`, key=`Value`; connection=`AebConnection`

- **Leitura v2:** `29 38 01 <ck>`

- **Escrita v2:** `37 38 16 01 <20 bytes LE> <ck>`

### 0x0139 — `INJR_GAS_FLOW` (TSTREAMDATI)

- **Caminho:** `StreamDati/INJR_GAS_FLOW`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `313`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 4096.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+4096); x=(0-4096*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `0.01`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`LandiConnect`, key=`InjrGasFlow`; connection=`AebConnection`

- **Leitura v2:** `0A 39 01 <index> <ck>`

- **Escrita v2:** `14 39 01 <index> <2 byte(s) LE> <ck>`

### 0x0139 — `TANK_VOL` (TSTREAMDATI)

- **Caminho:** `StreamDati/TANK_VOL`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `313`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1000.0, 0.0, 0.0, 32768.0]`

- **Fórmula exata:** `y=(1000*x+0)/(0*x+32768); x=(0-32768*y)/(0*y-1000)`; **unidade inferida:** `fator/índice`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`200.0`

- **Default:** `40.0`

- **INI/arquivo:** section=`LandiConnect`, key=`TankVol`; connection=`AebConnection`

- **Leitura v2:** `0A 39 01 <index> <ck>`

- **Escrita v2:** `14 39 01 <index> <2 byte(s) LE> <ck>`

### 0x013A — `NORM_TEMP` (TSTREAMDATI)

- **Caminho:** `StreamDati/NORM_TEMP`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `314`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `°C ou índice calibrado`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `293.0`

- **INI/arquivo:** section=`LandiConnect`, key=`NormTemp`; connection=`AebConnection`

- **Leitura v2:** `0A 3A 01 <index> <ck>`

- **Escrita v2:** `14 3A 01 <index> <2 byte(s) LE> <ck>`

### 0x013B — `NORM_PRESS` (TSTREAMDATI)

- **Caminho:** `StreamDati/NORM_PRESS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `315`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.01`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`-32.0`, max=`31.999`

- **Default:** `1.95`

- **INI/arquivo:** section=`LandiConnect`, key=`NormPress`; connection=`AebConnection`

- **Leitura v2:** `09 3B 01 <ck>`

- **Escrita v2:** `13 3B 01 <2 byte(s) LE> <ck>`

### 0x013C — `INJR_TOFS_PTR_H` (TSTREAMDATI)

- **Caminho:** `StreamDati/INJR_TOFS_PTR_H`

- **Classe:** `TAebVector`; **SerialCode decimal:** `316`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `0.01`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`-32.0`, max=`31.999`

- **Default:** `[4, 1.3, 1.95, 3.0, 5.5]`

- **INI/arquivo:** section=`LandiConnect`, key=`InjrTOfsPtrH`; connection=`AebConnection`

- **Leitura v2:** `29 3C 01 <ck>`

- **Escrita v2:** `37 3C 0A 01 <8 bytes LE> <ck>`

### 0x013D — `INJR_TOFS_PTR_V` (TSTREAMDATI)

- **Caminho:** `StreamDati/INJR_TOFS_PTR_V`

- **Classe:** `TAebVector`; **SerialCode decimal:** `317`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `0.01`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`-32.0`, max=`31.999`

- **Default:** `[5, 8.0, 10.0, 12.0, 14.0, 16.0]`

- **INI/arquivo:** section=`LandiConnect`, key=`InjrTOfsPtrV`; connection=`AebConnection`

- **Leitura v2:** `29 3D 01 <ck>`

- **Escrita v2:** `37 3D 0C 01 <10 bytes LE> <ck>`

### 0x013E — `INJR_TOFS_TBL` (TSTREAMDATI)

- **Caminho:** `StreamDati/INJR_TOFS_TBL`

- **Classe:** `TAebMatrix`; **SerialCode decimal:** `318`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 4096.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+4096); x=(0-4096*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `0.01`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `—`; **tipo:** `mtMatrix`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 5, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002, -0.5500000000000002]`

- **INI/arquivo:** section=`LandiConnect`, key=`InjrTOfsTbl`; connection=`AebConnection`

- **Leitura v2:** `2A 3E 01 <row> <ck> (ler por linha)`

- **Escrita v2:** `3x 3E <len?> 01 <row> <row-data> <ck> (SetVector indexado)`

### 0x013F — `GEAR_MAX_NO` (TSTREAMDATI)

- **Caminho:** `StreamDati/GEAR_MAX_NO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `319`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`7.0`

- **Default:** `5.0`

- **INI/arquivo:** section=`LandiConnect`, key=`GearMaxNo`; connection=`AebConnection`

- **Leitura v2:** `0A 3F 01 <index> <ck>`

- **Escrita v2:** `13 3F 01 <index> <1 byte(s) LE> <ck>`

### 0x013F — `GEAR_RAT_ADPY_EN` (TSTREAMDATI)

- **Caminho:** `StreamDati/GEAR_RAT_ADPY_EN`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `319`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `2.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`LandiConnect`, key=`GearRatAdpyEn`; connection=`AebConnection`

- **Leitura v2:** `0A 3F 01 <index> <ck>`

- **Escrita v2:** `13 3F 01 <index> <1 byte(s) LE> <ck>`

### 0x0140 — `MGSS_MAX_MNFLD_PRESS` (TSTREAMDATI)

- **Caminho:** `StreamDati/MGSS_MAX_MNFLD_PRESS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `320`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.01`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`-32.0`, max=`31.999`

- **Default:** `1.0`

- **INI/arquivo:** section=`LandiConnect`, key=`MgssMaxMnfldPress`; connection=`AebConnection`

- **Leitura v2:** `09 40 01 <ck>`

- **Escrita v2:** `13 40 01 <2 byte(s) LE> <ck>`

### 0x0141 — `DHLP_TANK_PRESS` (TSTREAMDATI)

- **Caminho:** `StreamDati/DHLP_TANK_PRESS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `321`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 41 01 <ck>`

- **Escrita v2:** `13 41 01 <2 byte(s) LE> <ck>`

### 0x0142 — `MDSB_INFO` (TSTREAMDATI)

- **Caminho:** `StreamDati/MDSB_INFO`

- **Classe:** `TAebVector`; **SerialCode decimal:** `322`

- **DataLength:** `4`; **DataMask:** `-1`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `14.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[14, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 42 01 <ck>`

- **Escrita v2:** `37 42 3A 01 <56 bytes LE> <ck>`

### 0x0143 — `EGEAR_RAT_BUF` (TSTREAMDATI)

- **Caminho:** `StreamDati/EGEAR_RAT_BUF`

- **Classe:** `TAebVector`; **SerialCode decimal:** `323`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `7.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[7, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 43 01 <ck>`

- **Escrita v2:** `37 43 10 01 <14 bytes LE> <ck>`

### 0x0144 — `MECO_INDEX` (TSTREAMDATI)

- **Caminho:** `StreamDati/MECO_INDEX`

- **Classe:** `TAebVector`; **SerialCode decimal:** `324`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `7.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[7, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 44 01 <ck>`

- **Escrita v2:** `37 44 10 01 <14 bytes LE> <ck>`

### 0x0145 — `MGLEV_DIAG_ERR` (TSTREAMDATI)

- **Caminho:** `StreamDati/MGLEV_DIAG_ERR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `325`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 45 01 <ck>`

- **Escrita v2:** `12 45 01 <1 byte(s) LE> <ck>`

### 0x0146 — `MGLEV_TANK_PRESS` (TSTREAMDATI)

- **Caminho:** `StreamDati/MGLEV_TANK_PRESS`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `326`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 46 01 <ck>`

- **Escrita v2:** `13 46 01 <2 byte(s) LE> <ck>`

### 0x0147 — `MGLEV_DATA` (TSTREAMDATI)

- **Caminho:** `StreamDati/MGLEV_DATA`

- **Classe:** `TAebVector`; **SerialCode decimal:** `327`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 47 01 <ck>`

- **Escrita v2:** `37 47 08 01 <6 bytes LE> <ck>`

### 0x0148 — `MGLEV_ERR_ST` (TSTREAMDATI)

- **Caminho:** `StreamDati/MGLEV_ERR_ST`

- **Classe:** `TAebVector`; **SerialCode decimal:** `328`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 48 01 <ck>`

- **Escrita v2:** `34 48 01 <3 bytes LE> <ck>`

### 0x0149 — `EGEAR_RAT_BUF_INST` (TSTREAMDATI)

- **Caminho:** `StreamDati/EGEAR_RAT_BUF_INST`

- **Classe:** `TAebVector`; **SerialCode decimal:** `329`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `7.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[7, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 49 01 <ck>`

- **Escrita v2:** `37 49 10 01 <14 bytes LE> <ck>`

### 0x014A — `AUTO_CAL_ENABLE` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/AUTO_CAL_ENABLE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `330`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`AutoCal`, key=`AutoCalEnable`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 4A 01 <ck>`

- **Escrita v2:** `12 4A 01 <1 byte(s) LE> <ck>`

### 0x014B — `PETR_INJ_TBP` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/PETR_INJ_TBP`

- **Classe:** `TAebVector`; **SerialCode decimal:** `331`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 512.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+512); x=(0-512*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `0.01`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 7.0, 8.0, 9.0, 10.0, 12.0, 14.0, 16.0, 18.0]`

- **INI/arquivo:** section=`AutoCal`, key=`PetrInjTBp`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 4B 01 <ck>`

- **Escrita v2:** `37 4B 26 01 <36 bytes LE> <ck>`

### 0x014C — `MNFLD_PRESS_THD` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/MNFLD_PRESS_THD`

- **Classe:** `TAebVector`; **SerialCode decimal:** `332`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.2, 0.245, 0.29, 0.335, 0.38, 0.425, 0.47, 0.515, 0.56, 0.605, 0.65, 0.695, 0.74, 0.785, 0.83, 0.87, 0.91, 0.95]`

- **INI/arquivo:** section=`AutoCal`, key=`MnfldPressThd`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 4C 01 <ck>`

- **Escrita v2:** `37 4C 26 01 <36 bytes LE> <ck>`

### 0x014E — `PETR_INJ_TBUF_GAS_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/PETR_INJ_TBUF_GAS_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `334`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 4E 01 <ck>`

- **Escrita v2:** `37 4E 26 01 <36 bytes LE> <ck>`

### 0x014F — `PETR_INJ_TBUF_GAS_PREV_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/PETR_INJ_TBUF_GAS_PREV_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `335`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 4F 01 <ck>`

- **Escrita v2:** `37 4F 26 01 <36 bytes LE> <ck>`

### 0x0150 — `PETR_INJ_TBUF_PETR_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/PETR_INJ_TBUF_PETR_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `336`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 50 01 <ck>`

- **Escrita v2:** `37 50 26 01 <36 bytes LE> <ck>`

### 0x0151 — `MNFLD_PRESS_BUF_GAS_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/MNFLD_PRESS_BUF_GAS_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `337`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 51 01 <ck>`

- **Escrita v2:** `37 51 26 01 <36 bytes LE> <ck>`

### 0x0152 — `MNFLD_PRESS_BUF_GAS_PREV_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/MNFLD_PRESS_BUF_GAS_PREV_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `338`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 52 01 <ck>`

- **Escrita v2:** `37 52 26 01 <36 bytes LE> <ck>`

### 0x0153 — `MNFLD_PRESS_BUF_PETR_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/MNFLD_PRESS_BUF_PETR_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `339`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 53 01 <ck>`

- **Escrita v2:** `37 53 26 01 <36 bytes LE> <ck>`

### 0x0154 — `BUF_UPD_GAS_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/BUF_UPD_GAS_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `340`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 54 01 <ck>`

- **Escrita v2:** `37 54 26 01 <36 bytes LE> <ck>`

### 0x0155 — `BUF_UPD_PETR_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/BUF_UPD_PETR_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `341`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 55 01 <ck>`

- **Escrita v2:** `37 55 26 01 <36 bytes LE> <ck>`

### 0x0156 — `VECT_EE_S16` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/VECT_EE_S16`

- **Classe:** `TAebVector`; **SerialCode decimal:** `342`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 56 01 <ck>`

- **Escrita v2:** `37 56 08 01 <6 bytes LE> <ck>`

### 0x0157 — `VECT_EE_U16` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/VECT_EE_U16`

- **Classe:** `TAebVector`; **SerialCode decimal:** `343`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `3.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[3, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 57 01 <ck>`

- **Escrita v2:** `37 57 08 01 <6 bytes LE> <ck>`

### 0x0158 — `MUL_ACT_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/MUL_ACT_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `344`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 58 01 <ck>`

- **Escrita v2:** `37 58 26 01 <36 bytes LE> <ck>`

### 0x0159 — `MUL_PREV_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/MUL_PREV_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `345`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 59 01 <ck>`

- **Escrita v2:** `37 59 26 01 <36 bytes LE> <ck>`

### 0x015A — `MUL_UPD_CALL_CNTR_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/MUL_UPD_CALL_CNTR_EE`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `346`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 5A 01 <ck>`

- **Escrita v2:** `12 5A 01 <1 byte(s) LE> <ck>`

### 0x015B — `NUM_BUF_UPD_PETR` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/NUM_BUF_UPD_PETR`

- **Classe:** `TAebVector`; **SerialCode decimal:** `347`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 5B 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x015C — `NUM_BUF_UPD_GAS` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/NUM_BUF_UPD_GAS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `348`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 5C 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x015D — `PETR_INJ_TBUF_GAS_PREV` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/PETR_INJ_TBUF_GAS_PREV`

- **Classe:** `TAebVector`; **SerialCode decimal:** `349`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 512.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+512); x=(0-512*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `0.01`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 5D 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x015E — `MNFLD_PRESS_BUF_GAS_PREV` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/MNFLD_PRESS_BUF_GAS_PREV`

- **Classe:** `TAebVector`; **SerialCode decimal:** `350`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `True`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 5E 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x015F — `PETR_INJ_TBUF_GAS` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/PETR_INJ_TBUF_GAS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `351`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 512.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+512); x=(0-512*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `0.01`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 5F 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x0160 — `MNFLD_PRESS_BUF_GAS` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/MNFLD_PRESS_BUF_GAS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `352`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `True`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 60 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x0161 — `MUL_ACT` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/MUL_ACT`

- **Classe:** `TAebVector`; **SerialCode decimal:** `353`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 16384.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+16384); x=(0-16384*y)/(0*y-1)`; **unidade inferida:** `fator/índice`; **precisão:** `0.001`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]`

- **INI/arquivo:** section=`AutoCal`, key=`AutoCalMulAct`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 61 01 <ck>`

- **Escrita v2:** `37 61 26 01 <36 bytes LE> <ck>`

### 0x0162 — `PETR_INJ_TBUF` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/PETR_INJ_TBUF`

- **Classe:** `TAebVector`; **SerialCode decimal:** `354`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 512.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+512); x=(0-512*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `0.01`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 62 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x0162 — `PETR_INJ_TBUF` (TSTREAMDATI)

- **Caminho:** `StreamDati/PETR_INJ_TBUF`

- **Classe:** `TAebVector`; **SerialCode decimal:** `354`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 512.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+512); x=(0-512*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `0.01`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 62 01 <ck>`

- **Escrita v2:** `37 62 26 01 <36 bytes LE> <ck>`

### 0x0163 — `MNFLD_PRESS_BUF` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/MNFLD_PRESS_BUF`

- **Classe:** `TAebVector`; **SerialCode decimal:** `355`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `True`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 63 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x0164 — `VECT_AUTOCAL_EE` (TAUTOCALDM_EE)

- **Caminho:** `AutoCalDM_EE/VECT_AUTOCAL_EE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `356`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 64 01 <ck>`

- **Escrita v2:** `37 64 0A 01 <8 bytes LE> <ck>`

### 0x0165 — `VECT_AUTOCAL_U8_0` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/VECT_AUTOCAL_U8_0`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `357`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `1.0`

- **INI/arquivo:** section=`AutoCal`, key=`AUTOCAL_IDLE_MIN_BUF_PETR_THD`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 65 01 <index> <ck>`

- **Escrita v2:** `13 65 01 <index> <1 byte(s) LE> <ck>`

### 0x0165 — `VECT_AUTOCAL_U8_1` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/VECT_AUTOCAL_U8_1`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `357`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `6.0`

- **INI/arquivo:** section=`AutoCal`, key=`AUTOCAL_IDLE_MIN_BUF_UPD_PETR_THD`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 65 01 <index> <ck>`

- **Escrita v2:** `13 65 01 <index> <1 byte(s) LE> <ck>`

### 0x0165 — `VECT_AUTOCAL_U8_2` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/VECT_AUTOCAL_U8_2`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `357`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `2.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`1.0`, max=`99.0`

- **Default:** `3.0`

- **INI/arquivo:** section=`AutoCal`, key=`MaxAutomatch`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 65 01 <index> <ck>`

- **Escrita v2:** `13 65 01 <index> <1 byte(s) LE> <ck>`

### 0x0167 — `EN_CDN_T_THD` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/EN_CDN_T_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `359`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `0.001`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `1.0`

- **INI/arquivo:** section=`AutoCal`, key=`EnCdnTThd`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 67 01 <index> <ck>`

- **Escrita v2:** `14 67 01 <index> <2 byte(s) LE> <ck>`

### 0x0169 — `LIMIT_PRESSURE_MIN` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/LIMIT_PRESSURE_MIN`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `361`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `0.05`

- **INI/arquivo:** section=`AutoCal`, key=`PressureMin`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 69 01 <ck>`

- **Escrita v2:** `13 69 01 <2 byte(s) LE> <ck>`

### 0x016A — `LIMIT_PRESSURE_MAX` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/LIMIT_PRESSURE_MAX`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `362`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `0.95`

- **INI/arquivo:** section=`AutoCal`, key=`PressureMax`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 6A 01 <ck>`

- **Escrita v2:** `13 6A 01 <2 byte(s) LE> <ck>`

### 0x016D — `PETROL_POINT_2DELETE` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/PETROL_POINT_2DELETE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `365`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`—`

- **Leitura v2:** `29 6D 01 <ck>`

- **Escrita v2:** `37 6D 14 01 <18 bytes LE> <ck>`

### 0x016E — `GAS_POINT_2DELETE` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/GAS_POINT_2DELETE`

- **Classe:** `TAebVector`; **SerialCode decimal:** `366`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`—`

- **Leitura v2:** `29 6E 01 <ck>`

- **Escrita v2:** `37 6E 14 01 <18 bytes LE> <ck>`

### 0x016F — `ACQUIRED_ZONES_PETROL` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/ACQUIRED_ZONES_PETROL`

- **Classe:** `TAebVector`; **SerialCode decimal:** `367`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 6F 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x0170 — `ACQUIRED_ZONES_GAS` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/ACQUIRED_ZONES_GAS`

- **Classe:** `TAebVector`; **SerialCode decimal:** `368`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `4.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[4, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 70 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x0172 — `CALIBRATION_VAL_1` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/CALIBRATION_VAL_1`

- **Classe:** `TAebVector`; **SerialCode decimal:** `370`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `10.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`AutoCal`, key=`CALIBRATION_VAL_1`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 72 01 <ck>`

- **Escrita v2:** `37 72 0C 01 <10 bytes LE> <ck>`

### 0x0173 — `MODULE_VERSION` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/MODULE_VERSION`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `371`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`AutoCal`, key=`MODULE_VERSION`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 73 01 <index> <ck>`

- **Escrita v2:** `somente leitura`

### 0x0174 — `NUM_ATUOMATCH_EXECUTED` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/NUM_ATUOMATCH_EXECUTED`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `372`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`AutoCal`, key=`NumAutomatchExecuted`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 74 01 <ck>`

- **Escrita v2:** `12 74 01 <1 byte(s) LE> <ck>`

### 0x0175 — `ClonedEcuDoneGasH` (TSTREAMDATI)

- **Caminho:** `StreamDati/ClonedEcuDoneGasH`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `373`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `0A 75 01 <index> <ck>`

- **Escrita v2:** `14 75 01 <index> <2 byte(s) LE> <ck>`

### 0x0175 — `ClonedEcuRemainingGasH` (TSTREAMDATI)

- **Caminho:** `StreamDati/ClonedEcuRemainingGasH`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `373`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `0A 75 01 <index> <ck>`

- **Escrita v2:** `14 75 01 <index> <2 byte(s) LE> <ck>`

### 0x0175 — `EN_LAMBDA_OVER_LVL_SENSOR` (TSTREAMDATI)

- **Caminho:** `StreamDati/EN_LAMBDA_OVER_LVL_SENSOR`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `373`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `V ou índice calibrado`; **precisão:** `1.0`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`1.0`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 75 01 <ck>`

- **Escrita v2:** `12 75 01 <1 byte(s) LE> <ck>`

### 0x0176 — `ClonedEcuIsBlocked` (TSTREAMDATI)

- **Caminho:** `StreamDati/ClonedEcuIsBlocked`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `374`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 76 01 <ck>`

- **Escrita v2:** `12 76 01 <1 byte(s) LE> <ck>`

### 0x0178 — `FF_ErrorCodeType` (TFFDATAMODULESINGLEARRAY)

- **Caminho:** `FFDataModuleSingleArray/FF_ErrorCodeType`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `376`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 78 01 <index> <ck>`

- **Escrita v2:** `13 78 01 <index> <1 byte(s) LE> <ck>`

### 0x0178 — `FF_FullBuffer` (TFFDATAMODULESINGLEARRAY)

- **Caminho:** `FFDataModuleSingleArray/FF_FullBuffer`

- **Classe:** `TAebVector`; **SerialCode decimal:** `376`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `82.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`True`, min=`—`, max=`—`

- **Default:** `[82, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 78 01 <ck>`

- **Escrita v2:** `somente leitura`

### 0x0178 — `FF_Version` (TFFDATAMODULESINGLEARRAY)

- **Caminho:** `FFDataModuleSingleArray/FF_Version`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `376`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `True`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 78 01 <index> <ck>`

- **Escrita v2:** `somente leitura`

### 0x0179 — `ABIL_FREEZEFRAME` (TSTREAMDATI)

- **Caminho:** `StreamDati/ABIL_FREEZEFRAME`

- **Classe:** `TAebVector`; **SerialCode decimal:** `377`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 255.0, 255.0, 255.0, 255.0, 255.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `29 79 01 <ck>`

- **Escrita v2:** `36 79 01 <5 bytes LE> <ck>`

### 0x017A — `MAX_RPM_FOR_AUTOCAL` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/MAX_RPM_FOR_AUTOCAL`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `378`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`400.0`, max=`8000.0`

- **Default:** `3000.0`

- **INI/arquivo:** section=`AutoCal`, key=`MaxRPMForAutocal`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 7A 01 <ck>`

- **Escrita v2:** `13 7A 01 <2 byte(s) LE> <ck>`

### 0x017B — `SP_EN_STRATEGIA_EMU_SENS_PRESS_CLIMA` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_EN_STRATEGIA_EMU_SENS_PRESS_CLIMA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `379`

- **DataLength:** `1`; **DataMask:** `4`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_EN_STRATEGIA_EMU_SENS_PRESS_CLIMA`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 7B 01 <ck>`

- **Escrita v2:** `12 7B 01 <1 byte(s) LE> <ck>`

### 0x017B — `SP_EN_STRATEGIA_MINIMO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_EN_STRATEGIA_MINIMO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `379`

- **DataLength:** `1`; **DataMask:** `1`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_EN_STRATEGIA_MINIMO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 7B 01 <ck>`

- **Escrita v2:** `12 7B 01 <1 byte(s) LE> <ck>`

### 0x017B — `SP_EN_STRATEGIA_RIC_CLIMA` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_EN_STRATEGIA_RIC_CLIMA`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `379`

- **DataLength:** `1`; **DataMask:** `2`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`255.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_EN_STRATEGIA_RIC_CLIMA`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 7B 01 <ck>`

- **Escrita v2:** `12 7B 01 <1 byte(s) LE> <ck>`

### 0x017C — `SP_SogliaAriaCondizionataON` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaAriaCondizionataON`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `9.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`5000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaAriaCondizionataON`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_SogliaDisinnescoGiri` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaDisinnescoGiri`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `3.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`500.0`, max=`2000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaDisinnescoGiri`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_SogliaDisinnescoMAP` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaDisinnescoMAP`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `5.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`100.0`, max=`600.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaDisinnescoMAP`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_SogliaDisinnescoTInj` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaDisinnescoTInj`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `4.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`2000.0`, max=`8000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaDisinnescoTInj`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_SogliaInnescoGiri` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaInnescoGiri`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`500.0`, max=`2000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaInnescoGiri`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_SogliaInnescoMAP` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaInnescoMAP`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `2.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`100.0`, max=`600.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaInnescoMAP`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_SogliaInnescoTInj` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaInnescoTInj`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`2000.0`, max=`6000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaInnescoTInj`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_SogliaMAPperEmulazioneContinuativa` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaMAPperEmulazioneContinuativa`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `8.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`100.0`, max=`500.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaMAPperEmulazioneContinuativa`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_TempoInterventoEmulazione` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_TempoInterventoEmulazione`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `6.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`1.0`, max=`10.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_TempoInterventoEmulazione`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017C — `SP_ValoreDiEmulazioneSensPress` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_ValoreDiEmulazioneSensPress`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `380`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `7.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`—`, max=`5000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_ValoreDiEmulazioneSensPress`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7C 01 <index> <ck>`

- **Escrita v2:** `14 7C 01 <index> <2 byte(s) LE> <ck>`

### 0x017D — `SP_SogliaDisinnescoGiri_CO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaDisinnescoGiri_CO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `381`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `3.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`500.0`, max=`2000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaDisinnescoGiri_CO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7D 01 <index> <ck>`

- **Escrita v2:** `14 7D 01 <index> <2 byte(s) LE> <ck>`

### 0x017D — `SP_SogliaDisinnescoMAP_CO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaDisinnescoMAP_CO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `381`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `5.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`100.0`, max=`600.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaDisinnescoMAP_CO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7D 01 <index> <ck>`

- **Escrita v2:** `14 7D 01 <index> <2 byte(s) LE> <ck>`

### 0x017D — `SP_SogliaDisinnescoTInj_CO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaDisinnescoTInj_CO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `381`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `4.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`2000.0`, max=`8000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaDisinnescoTInj_CO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7D 01 <index> <ck>`

- **Escrita v2:** `14 7D 01 <index> <2 byte(s) LE> <ck>`

### 0x017D — `SP_SogliaInnescoGiri_CO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaInnescoGiri_CO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `381`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `—`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`500.0`, max=`2000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaInnescoGiri_CO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7D 01 <index> <ck>`

- **Escrita v2:** `14 7D 01 <index> <2 byte(s) LE> <ck>`

### 0x017D — `SP_SogliaInnescoMAP_CO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaInnescoMAP_CO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `381`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `2.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`100.0`, max=`600.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaInnescoMAP_CO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7D 01 <index> <ck>`

- **Escrita v2:** `14 7D 01 <index> <2 byte(s) LE> <ck>`

### 0x017D — `SP_SogliaInnescoTInj_CO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaInnescoTInj_CO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `381`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `1.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`2000.0`, max=`6000.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaInnescoTInj_CO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7D 01 <index> <ck>`

- **Escrita v2:** `14 7D 01 <index> <2 byte(s) LE> <ck>`

### 0x017D — `SP_SogliaMAPperEmulazioneContinuativa_CO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_SogliaMAPperEmulazioneContinuativa_CO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `381`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `7.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`100.0`, max=`500.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_SogliaMAPperEmulazioneContinuativa_CO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7D 01 <index> <ck>`

- **Escrita v2:** `14 7D 01 <index> <2 byte(s) LE> <ck>`

### 0x017D — `SP_TempoInterventoEmulazione_CO` (TSTRATEGIAPANDADM)

- **Caminho:** `StrategiaPandaDM/SP_TempoInterventoEmulazione_CO`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `381`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `6.0`; **col_index:** `-1.0`; **tipo:** `ntVectorElement`

- **Limites:** disable=`False`, min=`1.0`, max=`10.0`

- **Default:** `—`

- **INI/arquivo:** section=`STRATEGIA_PANDA`, key=`SP_TempoInterventoEmulazione_CO`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `0A 7D 01 <index> <ck>`

- **Escrita v2:** `14 7D 01 <index> <2 byte(s) LE> <ck>`

### 0x017E — `SequenzaAutomaticaAcquisita` (TSTREAMDATI)

- **Caminho:** `StreamDati/SequenzaAutomaticaAcquisita`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `382`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 7E 01 <ck>`

- **Escrita v2:** `12 7E 01 <1 byte(s) LE> <ck>`

### 0x0183 — `DIFF_ENG_SPD_THD` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/DIFF_ENG_SPD_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `387`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`True`, min=`—`, max=`—`

- **Default:** `400.0`

- **INI/arquivo:** section=`AutoCal`, key=`DIFF_ENG_SPD_THD`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 83 01 <ck>`

- **Escrita v2:** `13 83 01 <2 byte(s) LE> <ck>`

### 0x0184 — `DELTA_ENG_SPD_THD` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/DELTA_ENG_SPD_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `388`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `rpm`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`True`, min=`—`, max=`—`

- **Default:** `200.0`

- **INI/arquivo:** section=`AutoCal`, key=`DELTA_ENG_SPD_THD`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 84 01 <ck>`

- **Escrita v2:** `13 84 01 <2 byte(s) LE> <ck>`

### 0x0185 — `DIFF_MNFLD_PRESS_THD` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/DIFF_MNFLD_PRESS_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `389`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`True`, min=`—`, max=`—`

- **Default:** `0.5`

- **INI/arquivo:** section=`AutoCal`, key=`DIFF_MNFLD_PRESS_THD`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 85 01 <ck>`

- **Escrita v2:** `13 85 01 <2 byte(s) LE> <ck>`

### 0x0186 — `DELTA_MNFLD_PRESS_THD` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/DELTA_MNFLD_PRESS_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `390`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `0.05`

- **INI/arquivo:** section=`AutoCal`, key=`DELTA_MNFLD_PRESS_THD`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 86 01 <ck>`

- **Escrita v2:** `13 86 01 <2 byte(s) LE> <ck>`

### 0x0187 — `DIFF_PETR_TINJ_T_THD` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/DIFF_PETR_TINJ_T_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `391`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 512.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+512); x=(0-512*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`True`, min=`—`, max=`—`

- **Default:** `4.0`

- **INI/arquivo:** section=`AutoCal`, key=`DIFF_PETR_TINJ_T_THD`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 87 01 <ck>`

- **Escrita v2:** `13 87 01 <2 byte(s) LE> <ck>`

### 0x0188 — `DELTA_PETR_INJ_T_THD` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/DELTA_PETR_INJ_T_THD`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `392`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 512.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+512); x=(0-512*y)/(0*y-1)`; **unidade inferida:** `ms ou s (ver nome/precisão)`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `1.0`

- **INI/arquivo:** section=`AutoCal`, key=`DELTA_PETR_INJ_T_THD`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 88 01 <ck>`

- **Escrita v2:** `13 88 01 <2 byte(s) LE> <ck>`

### 0x018B — `DISABLE_ACQ_BAND` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/DISABLE_ACQ_BAND`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `395`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`AutoCal`, key=`DISABLE_ACQ_BAND`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `09 8B 01 <ck>`

- **Escrita v2:** `12 8B 01 <1 byte(s) LE> <ck>`

### 0x018D — `PETR_MNFLD_PRESS_RV` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/PETR_MNFLD_PRESS_RV`

- **Classe:** `TAebVector`; **SerialCode decimal:** `397`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 0.2, 0.245, 0.29, 0.335, 0.38, 0.425, 0.47, 0.515, 0.56, 0.605, 0.65, 0.695, 0.74, 0.785, 0.83, 0.87, 0.91, 0.95]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 8D 01 <ck>`

- **Escrita v2:** `37 8D 26 01 <36 bytes LE> <ck>`

### 0x018E — `GAS_MNFLD_PRESS_RV` (TAUTOCALDM)

- **Caminho:** `AutoCalDM/GAS_MNFLD_PRESS_RV`

- **Classe:** `TAebVector`; **SerialCode decimal:** `398`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `True`; **ReadOnly:** `False`

- **Transformação:** `ttFormula`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1024.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1024); x=(0-1024*y)/(0*y-1)`; **unidade inferida:** `bar`; **precisão:** `0.001`

- **Dimensão:** `18.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[18, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 7.0, 8.0, 9.0, 10.0, 12.0, 14.0, 16.0, 18.0]`

- **INI/arquivo:** section=`—`, key=`—`; connection=`StreamDati.AebConnection`

- **Leitura v2:** `29 8E 01 <ck>`

- **Escrita v2:** `37 8E 26 01 <36 bytes LE> <ck>`

### 0x0190 — `PREHEAT_SYNC_INJ_NUM` (TSTREAMDATI)

- **Caminho:** `StreamDati/PREHEAT_SYNC_INJ_NUM`

- **Classe:** `TAebNumber`; **SerialCode decimal:** `400`

- **DataLength:** `1`; **DataMask:** `255`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `—`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `—`

- **INI/arquivo:** section=`—`, key=`—`; connection=`AebConnection`

- **Leitura v2:** `09 90 01 <ck>`

- **Escrita v2:** `12 90 01 <1 byte(s) LE> <ck>`

### 0x019E — `PARAMETRI_EXTRA_INJ` (TSTREAMDATI)

- **Caminho:** `StreamDati/PARAMETRI_EXTRA_INJ`

- **Classe:** `TAebVector`; **SerialCode decimal:** `414`

- **DataLength:** `2`; **DataMask:** `65535`; **Signed:** `False`; **ReadOnly:** `False`

- **Transformação:** `—`; **coeficientes [A,B,C,D]:** `[1.0, 0.0, 0.0, 1.0]`

- **Fórmula exata:** `y=(1*x+0)/(0*x+1); x=(0-1*y)/(0*y-1)`; **unidade inferida:** `—`; **precisão:** `—`

- **Dimensão:** `5.0`; **row_index:** `-1.0`; **col_index:** `-1.0`; **tipo:** `—`

- **Limites:** disable=`False`, min=`—`, max=`—`

- **Default:** `[5, 55.0, 400.0, 0.0, 200.0, 3500.0]`

- **INI/arquivo:** section=`PARAMETRI_EXTRA_INJ`, key=`Value`; connection=`AebConnection`

- **Leitura v2:** `29 9E 01 <ck>`

- **Escrita v2:** `37 9E 0C 01 <10 bytes LE> <ck>`

## APÊNDICE C — Catálogo das 800 requisições únicas observadas

> Esta tabela é evidência de tráfego. A presença de uma requisição não prova, sozinha, a semântica do botão que a originou.

| Request | Família | Subcmd/endereço | Extra | Ocorrências | CK | Variantes RX | Resposta principal | Qtd resposta | Endereço | Componentes | Recursos | Classes | Status RX | Payload RX | Decodificação |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 00 25 25 | control |  | 25 | 19 | True | 1 | 53 01 02 56 | 19 |  |  |  |  | ack | 02 |  |
| 01 04 54 59 | control |  | 0454 | 10 | True | 1 | CA 01 10 DB | 10 |  |  |  |  | ca_status | 01 10 |  |
| 01 11 00 12 | control |  | 1100 | 3 | True | 2 | 53 01 02 56 | 2 |  |  |  |  | ack | 02 |  |
| 01 12 00 13 | control |  | 1200 | 3 | True | 1 | 53 00 53 | 3 |  |  |  |  | ack |  |  |
| 00 01 01 | disconnect |  |  | 18 | True | 2 | 53 00 53 | 15 |  |  |  |  | ack |  |  |
| 09 01 00 0A | get_number | 1.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x0001 | REGISTRO_INIT | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 0A 00 13 | get_number | 10.0 |  | 8 | True | 1 | 53 01 1F 73 | 8 | 0x000A | RIF_SUP_LAMBDA_CALDA | TSTREAMDATI | TAebNumber | ack | 1F | [{"raw":31,"eng":31.0}] |
| 09 64 00 6D | get_number | 100.0 |  | 8 | True | 1 | 53 02 28 23 A0 | 8 | 0x0064 | GIRI_SUP_BENZINA | TSTREAMDATI | TAebNumber | ack | 28 23 | [{"raw":9000,"eng":9000.0}] |
| 09 6A 00 73 | get_number | 106.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x006A | NUMERO_INJ_BENZINA_CUTOFF \| SOGLIA_FLUSSO_SUBSONICO_LR | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 6B 00 74 | get_number | 107.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x006B | RITARDO_GIRI_EMULAZIONE_HIGH \| TAGLIA_INIETTORI_LR | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 6D 00 76 | get_number | 109.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x006D | TEMPO_SOVRAPPOSIZIONE | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 0B 00 14 | get_number | 11.0 |  | 8 | True | 1 | 53 01 0F 63 | 8 | 0x000B | RIF_INF_LAMBDA_CALDA | TSTREAMDATI | TAebNumber | ack | 0F | [{"raw":15,"eng":15.0}] |
| 09 6E 00 77 | get_number | 110.0 |  | 8 | True | 1 | 53 01 4B 9F | 8 | 0x006E | TEMPERATURA_GAS_AVVIO_LR \| TEMPO_CICCHETTO | TSTREAMDATI | TAebNumber \| TAebVector | ack | 4B | [{"raw":75,"eng":75.0}] |
| 09 74 00 7D | get_number | 116.0 |  | 8 | True | 1 | 53 01 32 86 | 8 | 0x0074 | CORR_ARRICCHIMENTO \| TIPO_CONNESSIONE_OBD_LR | TSTREAMDATI | TAebNumber | ack | 32 | [{"raw":50,"eng":50.0}] |
| 09 75 00 7E | get_number | 117.0 |  | 8 | True | 1 | 53 01 B6 0A | 8 | 0x0075 | TEMP_GAS_CAMBIO \| TEMP_RID_CAMBIO_LR | TSTREAMDATI | TAebNumber | ack | B6 | [{"raw":182,"eng":182.0}] |
| 09 76 00 7F | get_number | 118.0 |  | 8 | True | 1 | 53 01 14 68 | 8 | 0x0076 | IMPEDENZA_INIETTORI | TSTREAMDATI | TAebNumber | ack | 14 | [{"raw":20,"eng":20.0}] |
| 09 77 00 80 | get_number | 119.0 |  | 8 | True | 1 | 53 01 2D 81 | 8 | 0x0077 | VAL_PERC_HOLDING_CURRENT | TSTREAMDATI | TAebNumber | ack | 2D | [{"raw":45,"eng":45.0}] |
| 09 79 00 82 | get_number | 121.0 |  | 8 | True | 1 | 53 02 00 0A 5F | 8 | 0x0079 | BASE_TEMPI_GLOBALE | TSTREAMDATI | TAebNumber | ack | 00 0A | [{"raw":2560,"eng":2560.0}] |
| 09 7D 00 86 | get_number | 125.0 |  | 8 | True | 1 | 53 02 EA 00 3F | 8 | 0x007D | TEMPO_MORTO_INIETTORI_BENZINA | TSTREAMDATI | TAebNumber | ack | EA 00 | [{"raw":234,"eng":234.0}] |
| 09 7E 00 87 | get_number | 126.0 |  | 8 | True | 1 | 53 02 87 01 DD | 8 | 0x007E | TEMPO_MORTO_INIETTORI_GAS | TSTREAMDATI | TAebNumber | ack | 87 01 | [{"raw":391,"eng":391.0}] |
| 09 86 00 8F | get_number | 134.0 |  | 10 | True | 1 | 53 01 00 54 | 10 | 0x0086 | TIPO_SENSORE_TEMPERATURA | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 87 00 90 | get_number | 135.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x0087 | RITARDO_GIRI_EMULAZIONE | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 88 00 91 | get_number | 136.0 |  | 8 | True | 1 | 53 01 64 B8 | 8 | 0x0088 | SMAGRIMENTO_RIENTRO_CUTOFF | TSTREAMDATI | TAebNumber | ack | 64 | [{"raw":100,"eng":100.0}] |
| 09 89 00 92 | get_number | 137.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x0089 | NUMERO_INIETTATE_SMAGRIMENTO | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 90 00 99 | get_number | 144.0 |  | 8 | True | 1 | 53 01 43 97 | 8 | 0x0090 | TEMP_AUTOTARATURA | TSTREAMDATI | TAebNumber | ack | 43 | [{"raw":67,"eng":67.0}] |
| 09 92 00 9B | get_number | 146.0 |  | 8 | True | 1 | 53 02 4F 12 B6 | 8 | 0x0092 | T_INJ_BENZ_MAX_CAMBIO | TSTREAMDATI | TAebNumber | ack | 4F 12 | [{"raw":4687,"eng":4687.0}] |
| 09 93 00 9C | get_number | 147.0 |  | 8 | True | 1 | 53 02 75 00 CA | 8 | 0x0093 | SPOSTAMENTO_TARATURA | TSTREAMDATI | TAebNumber | ack | 75 00 | [{"raw":117,"eng":117.0}] |
| 09 0F 00 18 | get_number | 15.0 |  | 8 | True | 1 | 53 01 58 AC | 8 | 0x000F | TEMP_GAS_CAMBIO_LR \| TEMP_RID_CAMBIO | TSTREAMDATI | TAebNumber | ack | 58 | [{"raw":88,"eng":88.0}] |
| 09 96 00 9F | get_number | 150.0 |  | 8 | True | 1 | 53 02 58 02 AF | 8 | 0x0096 | GIRI_AUTOTARATURA | TSTREAMDATI | TAebNumber | ack | 58 02 | [{"raw":600,"eng":600.0}] |
| 09 9C 00 A5 | get_number | 156.0 |  | 8 | True | 1 | 53 02 23 02 7A | 8 | 0x009C | TEMPO_MAX_EXTRAINJ_BENZ | TSTREAMDATI | TAebNumber | ack | 23 02 | [{"raw":547,"eng":547.0}] |
| 09 10 00 19 | get_number | 16.0 |  | 8 | True | 1 | 53 02 B0 04 09 | 8 | 0x0010 | GIRI_MIN_CAMBIO | TSTREAMDATI | TAebNumber | ack | B0 04 | [{"raw":1200,"eng":1200.0}] |
| 09 11 00 1A | get_number | 17.0 |  | 8 | True | 1 | 53 01 23 77 | 8 | 0x0011 | RITARDO_CAMBIO | TSTREAMDATI | TAebNumber | ack | 23 | [{"raw":35,"eng":35.0}] |
| 09 AB 00 B4 | get_number | 171.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x00AB | RIF_TEMP_GAS_OFFSET_LR \| TIPI_SONDA_LAMBDA | TSTREAMDATI | TAebNumber \| TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 AC 00 B5 | get_number | 172.0 |  | 85 | True | 1 | 53 02 00 00 55 | 85 | 0x00AC | MASK_INIETTORI_BENZINA \| TEMPO_MORTO_INIETTORI_LR | TSTREAMDATI | TAebNumber \| TAebVector | ack | 00 00 | [{"raw":0,"eng":0.0}] |
| 09 B0 00 B9 | get_number | 176.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00B0 | GIRI_PER_BENZINA_LR \| LAMBDA_OFFSET | TSTREAMDATI | TAebNumber \| TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 09 B2 00 BB | get_number | 178.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00B2 | MASK_INIETTORI_BENZINA_LR \| RITARDO_CAMBIO_HIGH | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 09 12 00 1B | get_number | 18.0 |  | 8 | True | 1 | 53 02 00 00 55 | 8 | 0x0012 | TEST_WORD | TSTREAMDATI | TAebNumber | ack | 00 00 | [{"raw":0,"eng":0.0}] |
| 09 B4 00 BD | get_number | 180.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00B4 | SMAGRIMENTO_MIN | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 09 B5 00 BE | get_number | 181.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00B5 | TIPO_CARBURANTE | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 09 B6 00 BF | get_number | 182.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00B6 | SMP_CALIBRATO | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 09 BB 00 C4 | get_number | 187.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00BB | CORRETTORE_BANCATA2_LR \| TIPO_CONNESSIONE_OBD | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 09 BC 00 C5 | get_number | 188.0 |  | 8 | True | 1 | 53 01 55 A9 | 8 | 0x00BC | K_MAPPA_NEUTRO | TSTREAMDATI | TAebNumber | ack | 55 | [{"raw":85,"eng":85.0}] |
| 09 BF 00 C8 | get_number | 191.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00BF | SPLIT_FUEL | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 09 C3 00 CC | get_number | 195.0 |  | 8 | True | 1 | 53 01 32 86 | 8 | 0x00C3 | TEMP_GAS_CALDO | TSTREAMDATI | TAebNumber | ack | 32 | [{"raw":50,"eng":50.0}] |
| 09 02 00 0B | get_number | 2.0 |  | 11 | True | 1 | 53 01 AC 00 | 11 | 0x0002 | REGISTRO_EE | TSTREAMDATI | TAebNumber | ack | AC | [{"raw":172,"eng":172.0}] |
| 09 14 00 1D | get_number | 20.0 |  | 8 | True | 1 | 53 01 41 95 | 8 | 0x0014 | TIPO_ACCENS | TSTREAMDATI | TAebNumber | ack | 41 | [{"raw":65,"eng":65.0}] |
| 09 C8 00 D1 | get_number | 200.0 |  | 8 | True | 1 | 53 02 F4 01 4A | 8 | 0x00C8 | RPM_FOR_SPLIT_FUEL | TSTREAMDATI | TAebNumber | ack | F4 01 | [{"raw":500,"eng":500.0}] |
| 09 C9 00 D2 | get_number | 201.0 |  | 8 | True | 1 | 53 02 C4 09 22 | 8 | 0x00C9 | OVER_PRESSURE_DIAGNOSYS | TSTREAMDATI | TAebNumber | ack | C4 09 | [{"raw":2500,"eng":2500.0}] |
| 09 CF 00 D8 | get_number | 207.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00CF | RITARDO_ATTIVAZIONE_INIETTORI | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 09 15 00 1E | get_number | 21.0 |  | 10 | True | 1 | 53 01 04 58 | 10 | 0x0015 | MODELLO_HARDWARE | TSTREAMDATI | TAebNumber | ack | 04 | [{"raw":4,"eng":4.0}] |
| 09 D5 00 DE | get_number | 213.0 |  | 8 | True | 1 | 53 01 09 5D | 8 | 0x00D5 | NUMERO_PARTENZE_EMERGENZA | TSTREAMDATI | TAebNumber | ack | 09 | [{"raw":9,"eng":9.0}] |
| 09 16 00 1F | get_number | 22.0 |  | 8 | True | 1 | 53 01 05 59 | 8 | 0x0016 | SMAGRIMENTO_EXTRA \| TAGLIA_INIETTORE_LR | TSTREAMDATI | TAebNumber | ack | 05 | [{"raw":5,"eng":5.0}] |
| 09 DE 00 E7 | get_number | 222.0 |  | 8 | True | 1 | 53 01 36 8A | 8 | 0x00DE | SOGLIA_FLUSSO_SUBSONICO | TSTREAMDATI | TAebNumber | ack | 36 | [{"raw":54,"eng":54.0}] |
| 09 E1 00 EA | get_number | 225.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x00E1 | TAGLIA_INIETTORE | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 E6 00 EF | get_number | 230.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00E6 | SOGLIA_CORRETTORE_GAS | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 09 EF 00 F8 | get_number | 239.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00EF | SOGLIA_GIRI_ADATTATIVITA_WORD | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 09 F9 00 02 | get_number | 249.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x00F9 | NUM_DENTI_ALBERO_CAMME | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 3B 01 45 | get_number | 315.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x013B | NORM_PRESS | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4.00097656}] |
| 09 40 01 4A | get_number | 320.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0140 | MGSS_MAX_MNFLD_PRESS | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4.00097656}] |
| 09 21 00 2A | get_number | 33.0 |  | 208 | True | 1 | 53 01 00 54 | 208 | 0x0021 | DIAGNOSI_INJ_BENZ | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 4A 01 54 | get_number | 330.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x014A | AUTO_CAL_ENABLE | TAUTOCALDM | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 5A 01 64 | get_number | 346.0 |  | 8 | True | 1 | 53 01 03 57 | 8 | 0x015A | MUL_UPD_CALL_CNTR_EE | TAUTOCALDM_EE | TAebNumber | ack | 03 | [{"raw":3,"eng":3.0}] |
| 09 24 00 2D | get_number | 36.0 |  | 8 | True | 1 | 53 01 81 D5 | 8 | 0x0024 | TIPO_SENSORE | TSTREAMDATI | TAebNumber | ack | 81 | [{"raw":129,"eng":129.0}] |
| 09 69 01 73 | get_number | 361.0 |  | 8 | True | 1 | 53 02 AA 00 FF | 8 | 0x0169 | LIMIT_PRESSURE_MIN | TAUTOCALDM | TAebNumber | ack | AA 00 | [{"raw":170,"eng":0.16601562}] |
| 09 6A 01 74 | get_number | 362.0 |  | 8 | True | 1 | 53 02 C5 01 1B | 8 | 0x016A | LIMIT_PRESSURE_MAX | TAUTOCALDM | TAebNumber | ack | C5 01 | [{"raw":453,"eng":0.44238281}] |
| 09 74 01 7E | get_number | 372.0 |  | 8 | True | 1 | 53 01 03 57 | 8 | 0x0174 | NUM_ATUOMATCH_EXECUTED | TAUTOCALDM | TAebNumber | ack | 03 | [{"raw":3,"eng":3.0}] |
| 09 75 01 7F | get_number | 373.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0175 | ClonedEcuDoneGasH \| ClonedEcuRemainingGasH \| EN_LAMBDA_OVER_LVL_SENSOR | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 09 7A 01 84 | get_number | 378.0 |  | 8 | True | 1 | 53 02 B8 0B 18 | 8 | 0x017A | MAX_RPM_FOR_AUTOCAL | TAUTOCALDM | TAebNumber | ack | B8 0B | [{"raw":3000,"eng":3000.0}] |
| 09 7B 01 85 | get_number | 379.0 |  | 90 | True | 1 | 53 01 00 54 | 90 | 0x017B | SP_EN_STRATEGIA_EMU_SENS_PRESS_CLIMA \| SP_EN_STRATEGIA_MINIMO \| SP_EN_STRATEGIA_RIC_CLIMA | TSTRATEGIAPANDADM | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 7E 01 88 | get_number | 382.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x017E | SequenzaAutomaticaAcquisita | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 83 01 8D | get_number | 387.0 |  | 8 | True | 1 | 53 02 90 01 E6 | 8 | 0x0183 | DIFF_ENG_SPD_THD | TAUTOCALDM | TAebNumber | ack | 90 01 | [{"raw":400,"eng":400.0}] |
| 09 84 01 8E | get_number | 388.0 |  | 8 | True | 1 | 53 02 C8 00 1D | 8 | 0x0184 | DELTA_ENG_SPD_THD | TAUTOCALDM | TAebNumber | ack | C8 00 | [{"raw":200,"eng":200.0}] |
| 09 85 01 8F | get_number | 389.0 |  | 8 | True | 1 | 53 02 00 02 57 | 8 | 0x0185 | DIFF_MNFLD_PRESS_THD | TAUTOCALDM | TAebNumber | ack | 00 02 | [{"raw":512,"eng":0.5}] |
| 09 86 01 90 | get_number | 390.0 |  | 8 | True | 1 | 53 02 33 00 88 | 8 | 0x0186 | DELTA_MNFLD_PRESS_THD | TAUTOCALDM | TAebNumber | ack | 33 00 | [{"raw":51,"eng":0.04980469}] |
| 09 87 01 91 | get_number | 391.0 |  | 8 | True | 1 | 53 02 00 08 5D | 8 | 0x0187 | DIFF_PETR_TINJ_T_THD | TAUTOCALDM | TAebNumber | ack | 00 08 | [{"raw":2048,"eng":4.0}] |
| 09 88 01 92 | get_number | 392.0 |  | 8 | True | 1 | 53 02 00 02 57 | 8 | 0x0188 | DELTA_PETR_INJ_T_THD | TAUTOCALDM | TAebNumber | ack | 00 02 | [{"raw":512,"eng":1.0}] |
| 09 8B 01 95 | get_number | 395.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x018B | DISABLE_ACQ_BAND | TAUTOCALDM | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 04 00 0D | get_number | 4.0 |  | 8 | True | 1 | 53 01 02 56 | 8 | 0x0004 | TIPO_LAMBDA | TSTREAMDATI | TAebNumber | ack | 02 | [{"raw":2,"eng":2.0}] |
| 09 90 01 9A | get_number | 400.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0190 | PREHEAT_SYNC_INJ_NUM | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 09 05 00 0E | get_number | 5.0 |  | 8 | True | 1 | 53 01 1C 70 | 8 | 0x0005 | RIF_LAMBDA | TSTREAMDATI | TAebNumber | ack | 1C | [{"raw":28,"eng":28.0}] |
| 09 33 00 3C | get_number | 51.0 |  | 16 | True | 1 | 53 02 00 00 55 | 16 | 0x0033 | SUB_CLIENT_CODE \| TEMPO_CUTOFF_LR | TSTREAMDATI | TAebNumber | ack | 00 00 | [{"raw":0,"eng":0.0}] |
| 09 34 00 3D | get_number | 52.0 |  | 8 | True | 1 | 53 01 02 56 | 8 | 0x0034 | TIPO_INIEZIONE | TSTREAMDATI | TAebNumber | ack | 02 | [{"raw":2,"eng":2.0}] |
| 09 36 00 3F | get_number | 54.0 |  | 8 | True | 1 | 53 01 FF 53 | 8 | 0x0036 | TEMPO_INIEZIONE_CONTINUA | TSTREAMDATI | TAebNumber | ack | FF | [{"raw":255,"eng":255.0}] |
| 09 38 00 41 | get_number | 56.0 |  | 8 | True | 1 | 53 01 0B 5F | 8 | 0x0038 | CORRENTE_MANTENIMENTO | TSTREAMDATI | TAebNumber | ack | 0B | [{"raw":11,"eng":11.0}] |
| 09 3B 00 44 | get_number | 59.0 |  | 9 | True | 1 | 53 02 7E 02 D5 | 9 | 0x003B | TEMPO_GAS | TSTREAMDATI | TAebNumber | ack | 7E 02 | [{"raw":638,"eng":638.0}] |
| 09 06 00 0F | get_number | 6.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x0006 | RITARDO_SONDA | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 3C 00 45 | get_number | 60.0 |  | 9 | True | 1 | 53 02 6C 00 C1 | 9 | 0x003C | TEMPO_BENZINA | TSTREAMDATI | TAebNumber | ack | 6C 00 | [{"raw":108,"eng":108.0}] |
| 09 3E 00 47 | get_number | 62.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x003E | TEMPO_RITORNO_BENZINA | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 40 00 49 | get_number | 64.0 |  | 8 | True | 1 | 53 01 FE 52 | 8 | 0x0040 | CODICE_CLIENTE | TSTREAMDATI | TAebNumber | ack | FE | [{"raw":254,"eng":254.0}] |
| 09 07 00 10 | get_number | 7.0 |  | 8 | True | 1 | 53 01 05 59 | 8 | 0x0007 | TEMPO_LBD_FREDDA | TSTREAMDATI | TAebNumber | ack | 05 | [{"raw":5,"eng":5.0}] |
| 09 46 00 4F | get_number | 70.0 |  | 8 | True | 1 | 53 01 33 87 | 8 | 0x0046 | SOGLIA_RICCO_FORZATO | TSTREAMDATI | TAebNumber | ack | 33 | [{"raw":51,"eng":51.0}] |
| 09 47 00 50 | get_number | 71.0 |  | 8 | True | 1 | 53 01 29 7D | 8 | 0x0047 | LIVELLO_EMUL_ALTO | TSTREAMDATI | TAebNumber | ack | 29 | [{"raw":41,"eng":41.0}] |
| 09 48 00 51 | get_number | 72.0 |  | 8 | True | 1 | 53 01 05 59 | 8 | 0x0048 | LIVELLO_EMUL_BASSO | TSTREAMDATI | TAebNumber | ack | 05 | [{"raw":5,"eng":5.0}] |
| 09 49 00 52 | get_number | 73.0 |  | 8 | True | 1 | 53 02 64 08 C1 | 8 | 0x0049 | TEMPO_CORRENTE_CUTOFF | TSTREAMDATI | TAebNumber | ack | 64 08 | [{"raw":2148,"eng":2148.0}] |
| 09 4B 00 54 | get_number | 75.0 |  | 8 | True | 1 | 53 02 E8 03 40 | 8 | 0x004B | CILINDRATA | TSTREAMDATI | TAebNumber | ack | E8 03 | [{"raw":1000,"eng":1000.0}] |
| 09 4C 00 55 | get_number | 76.0 |  | 8 | True | 1 | 53 02 01 04 5A | 8 | 0x004C | MINIMA_VERSIONE_INTERFACCIA | TSTREAMDATI | TAebNumber | ack | 01 04 | [{"raw":1025,"eng":1025.0}] |
| 09 4E 00 57 | get_number | 78.0 |  | 8 | True | 1 | 53 01 00 54 | 8 | 0x004E | AVVIAMENTI_EMERGENZA | TSTREAMDATI | TAebNumber | ack | 00 | [{"raw":0,"eng":0.0}] |
| 09 4F 00 58 | get_number | 79.0 |  | 8 | True | 1 | 53 02 00 00 55 | 8 | 0x004F | PARAM_INJ | TSTREAMDATI | TAebNumber | ack | 00 00 | [{"raw":0,"eng":0.0}] |
| 09 08 00 11 | get_number | 8.0 |  | 8 | True | 1 | 53 01 1F 73 | 8 | 0x0008 | RIF_SUP_LAMBDA_FREDDA | TSTREAMDATI | TAebNumber | ack | 1F | [{"raw":31,"eng":31.0}] |
| 09 52 00 5B | get_number | 82.0 |  | 8 | True | 1 | 53 02 0D 03 65 | 8 | 0x0052 | TEMPO_CHIUSURA_INIETTORE | TSTREAMDATI | TAebNumber | ack | 0D 03 | [{"raw":781,"eng":781.0}] |
| 09 53 00 5C | get_number | 83.0 |  | 8 | True | 1 | 53 02 D1 03 29 | 8 | 0x0053 | TEMPO_APERTURA_INIETTORE | TSTREAMDATI | TAebNumber | ack | D1 03 | [{"raw":977,"eng":977.0}] |
| 09 55 00 5E | get_number | 85.0 |  | 8 | True | 2 | 53 02 28 08 85 | 7 | 0x0055 | TEMPO_GAS_PARZIALE | TSTREAMDATI | TAebNumber | ack | 28 08 | [{"raw":2088,"eng":2088.0}] |
| 09 58 00 61 | get_number | 88.0 |  | 8 | True | 1 | 53 02 38 04 91 | 8 | 0x0058 | TEMPO_TAGLIANDI | TSTREAMDATI | TAebNumber | ack | 38 04 | [{"raw":1080,"eng":1080.0}] |
| 09 09 00 12 | get_number | 9.0 |  | 8 | True | 1 | 53 01 0F 63 | 8 | 0x0009 | RIF_INF_LAMBDA_FREDDA | TSTREAMDATI | TAebNumber | ack | 0F | [{"raw":15,"eng":15.0}] |
| 09 5B 00 64 | get_number | 91.0 |  | 8 | True | 1 | 53 02 01 04 5A | 8 | 0x005B | WARNING_VERSIONE_INTERFACCIA | TSTREAMDATI | TAebNumber | ack | 01 04 | [{"raw":1025,"eng":1025.0}] |
| 0A 7C 00 00 86 | get_number_indexed | 124.0 | 00 | 10 | True | 1 | 53 02 39 0A 98 | 10 | 0x007C | COEFF_PRESS_DIFF | TSTREAMDATI | TAebVector | ack | 39 0A | [{"raw":2617,"eng":2617.0}] |
| 0A 1B 00 00 25 | get_number_indexed | 27.0 | 00 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 01 26 | get_number_indexed | 27.0 | 01 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 02 27 | get_number_indexed | 27.0 | 02 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 03 28 | get_number_indexed | 27.0 | 03 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 04 29 | get_number_indexed | 27.0 | 04 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 05 2A | get_number_indexed | 27.0 | 05 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 06 2B | get_number_indexed | 27.0 | 06 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 07 2C | get_number_indexed | 27.0 | 07 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 08 2D | get_number_indexed | 27.0 | 08 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 09 2E | get_number_indexed | 27.0 | 09 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 0A 2F | get_number_indexed | 27.0 | 0a | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 0B 30 | get_number_indexed | 27.0 | 0b | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 0C 31 | get_number_indexed | 27.0 | 0c | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 0D 32 | get_number_indexed | 27.0 | 0d | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 0E 33 | get_number_indexed | 27.0 | 0e | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 0F 34 | get_number_indexed | 27.0 | 0f | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 10 35 | get_number_indexed | 27.0 | 10 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 11 36 | get_number_indexed | 27.0 | 11 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 12 37 | get_number_indexed | 27.0 | 12 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 13 38 | get_number_indexed | 27.0 | 13 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 14 39 | get_number_indexed | 27.0 | 14 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 15 3A | get_number_indexed | 27.0 | 15 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 16 3B | get_number_indexed | 27.0 | 16 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 17 3C | get_number_indexed | 27.0 | 17 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 18 3D | get_number_indexed | 27.0 | 18 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 19 3E | get_number_indexed | 27.0 | 19 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 1A 3F | get_number_indexed | 27.0 | 1a | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 1B 40 | get_number_indexed | 27.0 | 1b | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 1C 41 | get_number_indexed | 27.0 | 1c | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 1D 42 | get_number_indexed | 27.0 | 1d | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 1E 43 | get_number_indexed | 27.0 | 1e | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 1F 44 | get_number_indexed | 27.0 | 1f | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 20 45 | get_number_indexed | 27.0 | 20 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 21 46 | get_number_indexed | 27.0 | 21 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 22 47 | get_number_indexed | 27.0 | 22 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 23 48 | get_number_indexed | 27.0 | 23 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 24 49 | get_number_indexed | 27.0 | 24 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 25 4A | get_number_indexed | 27.0 | 25 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 26 4B | get_number_indexed | 27.0 | 26 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 27 4C | get_number_indexed | 27.0 | 27 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 28 4D | get_number_indexed | 27.0 | 28 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 29 4E | get_number_indexed | 27.0 | 29 | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 2A 4F | get_number_indexed | 27.0 | 2a | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 2B 50 | get_number_indexed | 27.0 | 2b | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 2C 51 | get_number_indexed | 27.0 | 2c | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 2D 52 | get_number_indexed | 27.0 | 2d | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 2E 53 | get_number_indexed | 27.0 | 2e | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 1B 00 2F 54 | get_number_indexed | 27.0 | 2f | 8 | True | 1 | 53 01 00 54 | 8 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack | 00 | [{"raw":0,"eng":0.0}] |
| 0A 14 01 00 1F | get_number_indexed | 276.0 | 00 | 8 | True | 1 | 53 02 00 80 D5 | 8 | 0x0114 | LO_PASS_FILT_CON_FAST \| LO_PASS_FILT_CON_SLOW | TSTREAMDATI | TAebNumber | ack | 00 80 | [{"raw":32768,"eng":1.0}] |
| 0A 14 01 01 20 | get_number_indexed | 276.0 | 01 | 8 | True | 1 | 53 02 33 13 9B | 8 | 0x0114 | LO_PASS_FILT_CON_FAST \| LO_PASS_FILT_CON_SLOW | TSTREAMDATI | TAebNumber | ack | 33 13 | [{"raw":4915,"eng":0.1499939}] |
| 0A 23 01 01 2F | get_number_indexed | 291.0 | 01 | 9 | True | 1 | CA 01 10 DB | 9 | 0x0123 | PRESS_INSUL_DIAG_MIN_TANK_LVL_THD | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":16.00390625}] |
| 0A 24 01 01 30 | get_number_indexed | 292.0 | 01 | 9 | True | 1 | CA 01 10 DB | 9 | 0x0124 | LO_PRESS_INSUL_DIAG_FALL_THD | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4.00097656}] |
| 0A 25 01 02 32 | get_number_indexed | 293.0 | 02 | 9 | True | 1 | CA 01 10 DB | 9 | 0x0125 | PRESS_INSUL_DIAG_AFT_CRK_DLY \| PRESS_INSUL_DIAG_PRESS_ZNT \| PRESS_INSUL_DIAG_PRESS_ZNT_OUT | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4.00097656}] |
| 0A 25 01 03 33 | get_number_indexed | 293.0 | 03 | 9 | True | 1 | CA 01 10 DB | 9 | 0x0125 | PRESS_INSUL_DIAG_AFT_CRK_DLY \| PRESS_INSUL_DIAG_PRESS_ZNT \| PRESS_INSUL_DIAG_PRESS_ZNT_OUT | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4.00097656}] |
| 0A 25 01 04 34 | get_number_indexed | 293.0 | 04 | 9 | True | 1 | CA 01 10 DB | 9 | 0x0125 | PRESS_INSUL_DIAG_AFT_CRK_DLY \| PRESS_INSUL_DIAG_PRESS_ZNT \| PRESS_INSUL_DIAG_PRESS_ZNT_OUT | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4.00097656}] |
| 0A 27 01 00 32 | get_number_indexed | 295.0 | 00 | 9 | True | 1 | CA 01 10 DB | 9 | 0x0127 | PRESS_INSUL_DIAG_WAT_TEMP_HI_THD \| PRESS_INSUL_DIAG_WAT_TEMP_LO_THD | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 0A 27 01 01 33 | get_number_indexed | 295.0 | 01 | 9 | True | 1 | CA 01 10 DB | 9 | 0x0127 | PRESS_INSUL_DIAG_WAT_TEMP_HI_THD \| PRESS_INSUL_DIAG_WAT_TEMP_LO_THD | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 0A 2B 01 00 36 | get_number_indexed | 299.0 | 00 | 9 | True | 1 | CA 01 10 DB | 9 | 0x012B | PARAM_PROGRESS_0 \| PARAM_PROGRESS_1 \| PARAM_PROGRESS_2 \| PARAM_PROGRESS_3 | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 0A 2B 01 01 37 | get_number_indexed | 299.0 | 01 | 9 | True | 1 | CA 01 10 DB | 9 | 0x012B | PARAM_PROGRESS_0 \| PARAM_PROGRESS_1 \| PARAM_PROGRESS_2 \| PARAM_PROGRESS_3 | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 0A 2B 01 02 38 | get_number_indexed | 299.0 | 02 | 9 | True | 1 | CA 01 10 DB | 9 | 0x012B | PARAM_PROGRESS_0 \| PARAM_PROGRESS_1 \| PARAM_PROGRESS_2 \| PARAM_PROGRESS_3 | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 0A 2B 01 03 39 | get_number_indexed | 299.0 | 03 | 9 | True | 1 | CA 01 10 DB | 9 | 0x012B | PARAM_PROGRESS_0 \| PARAM_PROGRESS_1 \| PARAM_PROGRESS_2 \| PARAM_PROGRESS_3 | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 0A 2C 01 00 37 | get_number_indexed | 300.0 | 00 | 8 | True | 1 | 53 01 03 57 | 8 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack | 03 | [{"raw":3,"eng":3.0}] |
| 0A 2C 01 01 38 | get_number_indexed | 300.0 | 01 | 8 | True | 1 | 53 01 0A 5E | 8 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack | 0A | [{"raw":10,"eng":10.0}] |
| 0A 2C 01 02 39 | get_number_indexed | 300.0 | 02 | 8 | True | 1 | 53 01 25 79 | 8 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack | 25 | [{"raw":37,"eng":37.0}] |
| 0A 2C 01 03 3A | get_number_indexed | 300.0 | 03 | 8 | True | 1 | 53 01 3E 92 | 8 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack | 3E | [{"raw":62,"eng":62.0}] |
| 0A 2C 01 04 3B | get_number_indexed | 300.0 | 04 | 8 | True | 1 | 53 01 5A AE | 8 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack | 5A | [{"raw":90,"eng":90.0}] |
| 0A 2F 01 00 3A | get_number_indexed | 303.0 | 00 | 8 | True | 1 | 53 01 05 59 | 8 | 0x012F | ANTICIPO_INTERRUZIONE_WARMUP \| DELTA_AD_PER_WARMUP \| DELTA_T_RAIL_BLOCCO_DHLP | TSTREAMDATI | TAebNumber | ack | 05 | [{"raw":5,"eng":5.0}] |
| 0A 2F 01 01 3B | get_number_indexed | 303.0 | 01 | 8 | True | 1 | 53 01 0A 5E | 8 | 0x012F | ANTICIPO_INTERRUZIONE_WARMUP \| DELTA_AD_PER_WARMUP \| DELTA_T_RAIL_BLOCCO_DHLP | TSTREAMDATI | TAebNumber | ack | 0A | [{"raw":10,"eng":10.0}] |
| 0A 2F 01 02 3C | get_number_indexed | 303.0 | 02 | 8 | True | 1 | 53 01 03 57 | 8 | 0x012F | ANTICIPO_INTERRUZIONE_WARMUP \| DELTA_AD_PER_WARMUP \| DELTA_T_RAIL_BLOCCO_DHLP | TSTREAMDATI | TAebNumber | ack | 03 | [{"raw":3,"eng":3.0}] |
| 0A 39 01 00 44 | get_number_indexed | 313.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x0139 | INJR_GAS_FLOW \| TANK_VOL | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":125.03051758}] |
| 0A 39 01 01 45 | get_number_indexed | 313.0 | 01 | 8 | True | 1 | CA 01 10 DB | 8 | 0x0139 | INJR_GAS_FLOW \| TANK_VOL | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":125.03051758}] |
| 0A 3A 01 00 45 | get_number_indexed | 314.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x013A | NORM_TEMP | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 0A 3F 01 00 4A | get_number_indexed | 319.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x013F | GEAR_MAX_NO \| GEAR_RAT_ADPY_EN | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 0A 3F 01 02 4C | get_number_indexed | 319.0 | 02 | 8 | True | 1 | CA 01 10 DB | 8 | 0x013F | GEAR_MAX_NO \| GEAR_RAT_ADPY_EN | TSTREAMDATI | TAebNumber | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 0A 65 01 00 70 | get_number_indexed | 357.0 | 00 | 8 | True | 1 | 53 01 03 57 | 8 | 0x0165 | VECT_AUTOCAL_U8_0 \| VECT_AUTOCAL_U8_1 \| VECT_AUTOCAL_U8_2 | TAUTOCALDM | TAebNumber | ack | 03 | [{"raw":3,"eng":3.0}] |
| 0A 65 01 01 71 | get_number_indexed | 357.0 | 01 | 8 | True | 1 | 53 01 03 57 | 8 | 0x0165 | VECT_AUTOCAL_U8_0 \| VECT_AUTOCAL_U8_1 \| VECT_AUTOCAL_U8_2 | TAUTOCALDM | TAebNumber | ack | 03 | [{"raw":3,"eng":3.0}] |
| 0A 65 01 02 72 | get_number_indexed | 357.0 | 02 | 8 | True | 1 | 53 01 03 57 | 8 | 0x0165 | VECT_AUTOCAL_U8_0 \| VECT_AUTOCAL_U8_1 \| VECT_AUTOCAL_U8_2 | TAUTOCALDM | TAebNumber | ack | 03 | [{"raw":3,"eng":3.0}] |
| 0A 67 01 01 73 | get_number_indexed | 359.0 | 01 | 8 | True | 1 | 53 02 00 04 59 | 8 | 0x0167 | EN_CDN_T_THD | TAUTOCALDM | TAebNumber | ack | 00 04 | [{"raw":1024,"eng":1.0}] |
| 0A 73 01 00 7E | get_number_indexed | 371.0 | 00 | 40 | True | 1 | 53 01 04 58 | 40 | 0x0173 | MODULE_VERSION | TAUTOCALDM | TAebNumber | ack | 04 | [{"raw":4,"eng":4.0}] |
| 0A 7C 01 00 87 | get_number_indexed | 380.0 | 00 | 8 | True | 1 | 53 02 F4 01 4A | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | F4 01 | [{"raw":500,"eng":500.0}] |
| 0A 7C 01 01 88 | get_number_indexed | 380.0 | 01 | 8 | True | 1 | 53 02 D0 07 2C | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | D0 07 | [{"raw":2000,"eng":2000.0}] |
| 0A 7C 01 02 89 | get_number_indexed | 380.0 | 02 | 8 | True | 1 | 53 02 64 00 B9 | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | 64 00 | [{"raw":100,"eng":100.0}] |
| 0A 7C 01 03 8A | get_number_indexed | 380.0 | 03 | 8 | True | 1 | 53 02 F4 01 4A | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | F4 01 | [{"raw":500,"eng":500.0}] |
| 0A 7C 01 04 8B | get_number_indexed | 380.0 | 04 | 8 | True | 1 | 53 02 D0 07 2C | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | D0 07 | [{"raw":2000,"eng":2000.0}] |
| 0A 7C 01 05 8C | get_number_indexed | 380.0 | 05 | 8 | True | 1 | 53 02 64 00 B9 | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | 64 00 | [{"raw":100,"eng":100.0}] |
| 0A 7C 01 06 8D | get_number_indexed | 380.0 | 06 | 8 | True | 1 | 53 02 01 00 56 | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | 01 00 | [{"raw":1,"eng":1.0}] |
| 0A 7C 01 07 8E | get_number_indexed | 380.0 | 07 | 8 | True | 1 | 53 02 00 00 55 | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | 00 00 | [{"raw":0,"eng":0.0}] |
| 0A 7C 01 08 8F | get_number_indexed | 380.0 | 08 | 8 | True | 1 | 53 02 64 00 B9 | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | 64 00 | [{"raw":100,"eng":100.0}] |
| 0A 7C 01 09 90 | get_number_indexed | 380.0 | 09 | 8 | True | 1 | 53 02 00 00 55 | 8 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack | 00 00 | [{"raw":0,"eng":0.0}] |
| 0A 7D 01 00 88 | get_number_indexed | 381.0 | 00 | 8 | True | 1 | 53 02 F4 01 4A | 8 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack | F4 01 | [{"raw":500,"eng":500.0}] |
| 0A 7D 01 01 89 | get_number_indexed | 381.0 | 01 | 8 | True | 1 | 53 02 D0 07 2C | 8 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack | D0 07 | [{"raw":2000,"eng":2000.0}] |
| 0A 7D 01 02 8A | get_number_indexed | 381.0 | 02 | 8 | True | 1 | 53 02 64 00 B9 | 8 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack | 64 00 | [{"raw":100,"eng":100.0}] |
| 0A 7D 01 03 8B | get_number_indexed | 381.0 | 03 | 8 | True | 1 | 53 02 F4 01 4A | 8 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack | F4 01 | [{"raw":500,"eng":500.0}] |
| 0A 7D 01 04 8C | get_number_indexed | 381.0 | 04 | 8 | True | 1 | 53 02 D0 07 2C | 8 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack | D0 07 | [{"raw":2000,"eng":2000.0}] |
| 0A 7D 01 05 8D | get_number_indexed | 381.0 | 05 | 8 | True | 1 | 53 02 64 00 B9 | 8 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack | 64 00 | [{"raw":100,"eng":100.0}] |
| 0A 7D 01 06 8E | get_number_indexed | 381.0 | 06 | 8 | True | 1 | 53 02 01 00 56 | 8 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack | 01 00 | [{"raw":1,"eng":1.0}] |
| 0A 7D 01 07 8F | get_number_indexed | 381.0 | 07 | 8 | True | 1 | 53 02 64 00 B9 | 8 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack | 64 00 | [{"raw":100,"eng":100.0}] |
| 29 00 00 29 | get_vector | 0.0 |  | 92 | True | 1 | 53 14 34 5A 30 33 78 41 63 67 48 62 37 46 75 30 72 59 65 6A 41 73 F5 | 92 | 0x0000 |  |  |  | ack | 34 5A 30 33 78 41 63 67 48 62 37 46 75 30 72 59 65 6A 41 73 |  |
| 29 68 00 91 | get_vector | 104.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0068 | RIF_PRESS_ASS_LR \| TEMP_ACQUA_MONOFUEL | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 6F 00 98 | get_vector | 111.0 |  | 8 | True | 1 | 53 08 90 01 58 02 20 03 E8 03 54 | 8 | 0x006F | RIF_MAP_SONDA_LAMBDA \| RITARDO_PASSAGGIO_GAS_LR | TSTREAMDATI | TAebVector | ack | 90 01 58 02 20 03 E8 03 | [{"raw":400,"eng":400.0},{"raw":600,"eng":600.0},{"raw":800,"eng":800.0},{"raw":1000,"eng":1000.0}] |
| 29 72 00 9B | get_vector | 114.0 |  | 8 | True | 1 | 53 18 C2 01 F4 01 26 02 58 02 8A 02 BC 02 EE 02 20 03 52 03 84 03 B6 03 E8 03 82 | 8 | 0x0072 | MAP_BENZINA_LR \| MAP_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | C2 01 F4 01 26 02 58 02 8A 02 BC 02 EE 02 20 03 52 03 84 03 B6 03 E8 03 | [{"raw":450,"eng":450.0},{"raw":500,"eng":500.0},{"raw":550,"eng":550.0},{"raw":600,"eng":600.0},{"raw":650,"eng":650.0},{"raw":700,"eng":700.0},{"raw":750,"eng":750.0},{"raw":800,"eng":800.0},{"raw":850,"eng":850.0},{"raw":900,"eng":900.0},{"raw":950,"eng":950.0},{"raw":1000,"eng":1000.0}] |
| 29 73 00 9C | get_vector | 115.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0073 | RIF_MAP_BENZINA_LR \| SGANCIO_FILTRO_BENZINA | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 0C 00 35 | get_vector | 12.0 |  | 8 | True | 1 | 53 18 F4 01 E8 03 DC 05 D0 07 C4 09 B8 0B AC 0D A0 0F 94 11 88 13 7C 15 70 17 53 | 8 | 0x000C | RIF_GIRI | TSTREAMDATI | TAebVector | ack | F4 01 E8 03 DC 05 D0 07 C4 09 B8 0B AC 0D A0 0F 94 11 88 13 7C 15 70 17 | [{"raw":500,"eng":500.0},{"raw":1000,"eng":1000.0},{"raw":1500,"eng":1500.0},{"raw":2000,"eng":2000.0},{"raw":2500,"eng":2500.0},{"raw":3000,"eng":3000.0},{"raw":3500,"eng":3500.0},{"raw":4000,"eng":4000.0},{"raw":4500,"eng":4500.0},{"raw":5000,"eng":5000.0},{"raw":5500,"eng":5500.0},{"raw":6000,"eng":6000.0}] |
| 29 78 00 A1 | get_vector | 120.0 |  | 8 | True | 1 | 53 0C 64 00 F4 01 64 00 F4 01 23 00 3A 03 71 | 8 | 0x0078 | MAP_ESTERNO | TSTREAMDATI | TAebVector | ack | 64 00 F4 01 64 00 F4 01 23 00 3A 03 | [{"raw":100,"eng":100.0},{"raw":500,"eng":500.0},{"raw":100,"eng":100.0},{"raw":500,"eng":500.0},{"raw":35,"eng":35.0},{"raw":826,"eng":826.0}] |
| 29 7B 00 A4 | get_vector | 123.0 |  | 8 | True | 1 | 53 1E E2 04 2C 05 77 05 C3 05 0E 06 59 06 A3 06 EE 06 3A 07 85 07 D0 07 23 08 77 08 CB 08 1F 09 25 | 8 | 0x007B | RIF_PRESS_DIFF | TSTREAMDATI | TAebVector | ack | E2 04 2C 05 77 05 C3 05 0E 06 59 06 A3 06 EE 06 3A 07 85 07 D0 07 23 08 77 08 CB 08 1F 09 | [{"raw":1250,"eng":1250.0},{"raw":1324,"eng":1324.0},{"raw":1399,"eng":1399.0},{"raw":1475,"eng":1475.0},{"raw":1550,"eng":1550.0},{"raw":1625,"eng":1625.0},{"raw":1699,"eng":1699.0},{"raw":1774,"eng":1774.0},{"raw":1850,"eng":1850.0},{"raw":1925,"eng":1925.0},{"raw":2000,"eng":2000.0},{"raw":2083,"eng":2083.0},{"raw":2167,"eng":2167.0},{"raw":2251,"eng":2251.0},{"raw":2335,"eng":2335.0}] |
| 29 7C 00 A5 | get_vector | 124.0 |  | 8 | True | 1 | 53 1E 39 0A 15 09 F9 07 E5 06 D7 05 D0 04 CF 03 D4 02 DD 01 EC 00 00 00 FD FE FF FD 06 FD 11 FC E6 | 8 | 0x007C | COEFF_PRESS_DIFF | TSTREAMDATI | TAebVector | ack | 39 0A 15 09 F9 07 E5 06 D7 05 D0 04 CF 03 D4 02 DD 01 EC 00 00 00 FD FE FF FD 06 FD 11 FC | [{"raw":2617,"eng":2617.0},{"raw":2325,"eng":2325.0},{"raw":2041,"eng":2041.0},{"raw":1765,"eng":1765.0},{"raw":1495,"eng":1495.0},{"raw":1232,"eng":1232.0},{"raw":975,"eng":975.0},{"raw":724,"eng":724.0},{"raw":477,"eng":477.0},{"raw":236,"eng":236.0},{"raw":0,"eng":0.0},{"raw":-259,"eng":-259.0},{"raw":-513,"eng":-513.0},{"raw":-762,"eng":-762.0},{"raw":-1007,"eng":-1007.0}] |
| 29 7F 00 A8 | get_vector | 127.0 |  | 8 | True | 1 | 53 18 C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D DB | 8 | 0x007F | TEMPI_K_OPENLOOP | TSTREAMDATI | TAebVector | ack | C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D | [{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0},{"raw":11719,"eng":11719.0}] |
| 29 82 00 AB | get_vector | 130.0 |  | 8 | True | 1 | 53 0C 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 97 | 8 | 0x0082 | RIF_SONDA_LAMBDA | TSTREAMDATI | TAebVector | ack | 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A | [{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0}] |
| 29 83 00 AC | get_vector | 131.0 |  | 8 | True | 1 | 53 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 6B | 8 | 0x0083 | RIT_EMUL_RICCA | TSTREAMDATI | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 84 00 AD | get_vector | 132.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0084 | RIF_DELAY_LAMBDA | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 29 8A 00 B3 | get_vector | 138.0 |  | 8 | True | 1 | 53 05 12 5C 05 EC 1E D5 | 8 | 0x008A | PARAMETRI_TEMP | TSTREAMDATI | TAebVector | ack | 12 5C 05 EC 1E | [{"raw":18,"eng":18.0},{"raw":92,"eng":92.0},{"raw":5,"eng":5.0},{"raw":-20,"eng":-20.0},{"raw":30,"eng":30.0}] |
| 29 8B 00 B4 | get_vector | 139.0 |  | 8 | True | 1 | 53 1E E7 E0 D8 CE C3 B7 AA 9C 8E 80 72 65 59 4E 44 3B 33 2C 26 21 1D 19 16 13 10 0E 0C 0B 0A 08 F5 | 8 | 0x008B | ECU_TEMP | TSTREAMDATI | TAebVector | ack | E7 E0 D8 CE C3 B7 AA 9C 8E 80 72 65 59 4E 44 3B 33 2C 26 21 1D 19 16 13 10 0E 0C 0B 0A 08 | [{"raw":231,"eng":231.0},{"raw":224,"eng":224.0},{"raw":216,"eng":216.0},{"raw":206,"eng":206.0},{"raw":195,"eng":195.0},{"raw":183,"eng":183.0},{"raw":170,"eng":170.0},{"raw":156,"eng":156.0},{"raw":142,"eng":142.0},{"raw":128,"eng":128.0},{"raw":114,"eng":114.0},{"raw":101,"eng":101.0},{"raw":89,"eng":89.0},{"raw":78,"eng":78.0},{"raw":68,"eng":68.0},{"raw":59,"eng":59.0},{"raw":51,"eng":51.0},{"raw":44,"eng":44.0},{"raw":38,"eng":38.0},{"raw":33,"eng":33.0},{"raw":29,"eng":29.0},{"raw":25,"eng":25.0},{"raw":22,"eng":22.0},{"raw":19,"eng":19.0},{"raw":16,"eng":16.0},{"raw":14,"eng":14.0},{"raw":12,"eng":12.0},{"raw":11,"eng":11.0},{"raw":10,"eng":10.0},{"raw":8,"eng":8.0}] |
| 29 91 00 BA | get_vector | 145.0 |  | 8 | True | 1 | 53 04 27 00 00 00 7E | 8 | 0x0091 | SCARTO_MINIMO_TARATURA | TSTREAMDATI | TAebVector | ack | 27 00 00 00 | [{"raw":39,"eng":39.0},{"raw":0,"eng":0.0}] |
| 29 94 00 BD | get_vector | 148.0 |  | 16 | True | 1 | 53 02 1B 25 95 | 16 | 0x0094 | TIPO_INIETTORE | TSTREAMDATI | TAebVector | ack | 1B 25 | [{"raw":27,"eng":27.0},{"raw":37,"eng":37.0}] |
| 29 97 00 C0 | get_vector | 151.0 |  | 8 | True | 1 | 53 03 01 05 02 5E | 8 | 0x0097 | PARAM_AUTOTARATURA | TSTREAMDATI | TAebVector | ack | 01 05 02 | [{"raw":1,"eng":1.0},{"raw":5,"eng":5.0},{"raw":2,"eng":2.0}] |
| 29 98 00 C1 | get_vector | 152.0 |  | 8 | True | 1 | 53 10 E8 03 D1 03 35 0C 84 1E 94 04 4F 12 18 23 84 1E DB | 8 | 0x0098 | PRESS_BASSA_RETROPAS_LR \| TINJ_FILTRO | TSTREAMDATI | TAebNumber \| TAebVector | ack | E8 03 D1 03 35 0C 84 1E 94 04 4F 12 18 23 84 1E | [{"raw":1000,"eng":1000.0},{"raw":977,"eng":977.0},{"raw":3125,"eng":3125.0},{"raw":7812,"eng":7812.0},{"raw":1172,"eng":1172.0},{"raw":4687,"eng":4687.0},{"raw":8984,"eng":8984.0},{"raw":7812,"eng":7812.0}] |
| 29 9B 00 C4 | get_vector | 155.0 |  | 8 | True | 1 | 53 06 00 00 00 00 27 00 80 | 8 | 0x009B | TEMPI_EXTRAINIETTATE | TSTREAMDATI | TAebVector | ack | 00 00 00 00 27 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":39,"eng":39.0}] |
| 29 9E 00 C7 | get_vector | 158.0 |  | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x009E | CORRETTORE_BANCATA2 \| TEMPERATURA_ACQUA_AVVIO_LR | TSTREAMDATI | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 A0 00 C9 | get_vector | 160.0 |  | 8 | True | 1 | 53 08 C7 2D 00 00 00 00 C7 2D 43 | 8 | 0x00A0 | SEQUENZA_INJ_LR \| TEMPI_PER_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | C7 2D 00 00 00 00 C7 2D | [{"raw":11719,"eng":11719.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":11719,"eng":11719.0}] |
| 29 A1 00 CA | get_vector | 161.0 |  | 8 | True | 1 | 53 04 00 00 34 21 AC | 8 | 0x00A1 | GIRI_PER_BENZINA \| SEQUENZA_INJ_BENZ_LR | TSTREAMDATI | TAebVector | ack | 00 00 34 21 | [{"raw":0,"eng":0.0},{"raw":8500,"eng":8500.0}] |
| 29 A3 00 CC | get_vector | 163.0 |  | 8 | True | 1 | 53 02 14 05 6E | 8 | 0x00A3 | INIETTATE_PER_BENZINA \| RIF_MAP_ANTICIPO_LR | TSTREAMDATI | TAebVector | ack | 14 05 | [{"raw":20,"eng":20.0},{"raw":5,"eng":5.0}] |
| 29 AA 00 D3 | get_vector | 170.0 |  | 8 | True | 1 | 53 02 05 24 7E | 8 | 0x00AA | EMULAZIONE_POSTERIORE | TSTREAMDATI | TAebVector | ack | 05 24 | [{"raw":5,"eng":5.0},{"raw":36,"eng":36.0}] |
| 29 B3 00 DC | get_vector | 179.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00B3 | CHANGE_OVER | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 29 B9 00 E2 | get_vector | 185.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00B9 | CONFIGURA_ADATTA | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 BD 00 E6 | get_vector | 189.0 |  | 8 | True | 1 | 53 18 08 07 08 07 6C 07 D0 07 D0 07 D0 07 34 08 34 08 34 08 5C 08 5C 08 98 08 9D | 8 | 0x00BD | CONFIGURA_ADATTA_LR \| PRESS_RETROPASSAGGIO | TSTREAMDATI | TAebVector | ack | 08 07 08 07 6C 07 D0 07 D0 07 D0 07 34 08 34 08 34 08 5C 08 5C 08 98 08 | [{"raw":1800,"eng":1800.0},{"raw":1800,"eng":1800.0},{"raw":1900,"eng":1900.0},{"raw":2000,"eng":2000.0},{"raw":2000,"eng":2000.0},{"raw":2000,"eng":2000.0},{"raw":2100,"eng":2100.0},{"raw":2100,"eng":2100.0},{"raw":2100,"eng":2100.0},{"raw":2140,"eng":2140.0},{"raw":2140,"eng":2140.0},{"raw":2200,"eng":2200.0}] |
| 29 C0 00 E9 | get_vector | 192.0 |  | 8 | True | 1 | 53 04 01 00 00 00 58 | 8 | 0x00C0 | FLAG_CONF2 | TSTREAMDATI | TAebVector | ack | 01 00 00 00 | [{"raw":1,"eng":1.0},{"raw":0,"eng":0.0}] |
| 29 C2 00 EB | get_vector | 194.0 |  | 10 | True | 1 | 53 1E 7F 0D 03 F8 01 00 ED DD 37 20 3F BC 91 90 43 15 44 06 C0 00 00 00 00 00 00 00 00 00 00 00 98 | 10 | 0x00C2 | MASK_FUNCTION | TSTREAMDATI | TAebVector | ack | 7F 0D 03 F8 01 00 ED DD 37 20 3F BC 91 90 43 15 44 06 C0 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":127,"eng":127.0},{"raw":13,"eng":13.0},{"raw":3,"eng":3.0},{"raw":248,"eng":248.0},{"raw":1,"eng":1.0},{"raw":0,"eng":0.0},{"raw":237,"eng":237.0},{"raw":221,"eng":221.0},{"raw":55,"eng":55.0},{"raw":32,"eng":32.0},{"raw":63,"eng":63.0},{"raw":188,"eng":188.0},{"raw":145,"eng":145.0},{"raw":144,"eng":144.0},{"raw":67,"eng":67.0},{"raw":21,"eng":21.0},{"raw":68,"eng":68.0},{"raw":6,"eng":6.0},{"raw":192,"eng":192.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 C4 00 ED | get_vector | 196.0 |  | 8 | True | 1 | 53 0A 2A 2C 2E 30 32 34 36 38 3A 3C 5B | 8 | 0x00C4 | RIF_PRESS_SPLIT_FUEL | TSTREAMDATI | TAebVector | ack | 2A 2C 2E 30 32 34 36 38 3A 3C | [{"raw":42,"eng":42.0},{"raw":44,"eng":44.0},{"raw":46,"eng":46.0},{"raw":48,"eng":48.0},{"raw":50,"eng":50.0},{"raw":52,"eng":52.0},{"raw":54,"eng":54.0},{"raw":56,"eng":56.0},{"raw":58,"eng":58.0},{"raw":60,"eng":60.0}] |
| 29 C5 00 EE | get_vector | 197.0 |  | 8 | True | 1 | 53 0A 00 00 00 00 00 00 00 00 00 00 5D | 8 | 0x00C5 | COEFF_PRESS_SPLIT_FUEL | TSTREAMDATI | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 C6 00 EF | get_vector | 198.0 |  | 8 | True | 1 | 53 08 4A 02 3A 00 94 04 55 00 CE | 8 | 0x00C6 | K_FACTOR_PARAM | TSTREAMDATI | TAebVector | ack | 4A 02 3A 00 94 04 55 00 | [{"raw":586,"eng":586.0},{"raw":58,"eng":58.0},{"raw":1172,"eng":1172.0},{"raw":85,"eng":85.0}] |
| 29 DB 00 04 | get_vector | 219.0 |  | 8 | True | 1 | 53 0C FC 08 16 00 00 00 00 00 74 00 00 00 ED | 8 | 0x00DB | ADVANCED_PARAM_INJ | TSTREAMDATI | TAebVector | ack | FC 08 16 00 00 00 00 00 74 00 00 00 | [{"raw":2300,"eng":2300.0},{"raw":22,"eng":22.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":116,"eng":116.0},{"raw":0,"eng":0.0}] |
| 29 DC 00 05 | get_vector | 220.0 |  | 8 | True | 1 | 53 09 00 26 32 43 58 71 8D A9 FF F5 | 8 | 0x00DC | TEMPERATURA_ACQUA_AVVIO | TSTREAMDATI | TAebVector | ack | 00 26 32 43 58 71 8D A9 FF | [{"raw":0,"eng":0.0},{"raw":38,"eng":38.0},{"raw":50,"eng":50.0},{"raw":67,"eng":67.0},{"raw":88,"eng":88.0},{"raw":113,"eng":113.0},{"raw":141,"eng":141.0},{"raw":169,"eng":169.0},{"raw":255,"eng":255.0}] |
| 29 DD 00 06 | get_vector | 221.0 |  | 8 | True | 1 | 53 08 0F 14 19 1E 28 2D 32 32 6E | 8 | 0x00DD | RITARDO_PASSAGGIO | TSTREAMDATI | TAebVector | ack | 0F 14 19 1E 28 2D 32 32 | [{"raw":15,"eng":15.0},{"raw":20,"eng":20.0},{"raw":25,"eng":25.0},{"raw":30,"eng":30.0},{"raw":40,"eng":40.0},{"raw":45,"eng":45.0},{"raw":50,"eng":50.0},{"raw":50,"eng":50.0}] |
| 29 DF 00 08 | get_vector | 223.0 |  | 8 | True | 1 | 53 0F 3A 3D 41 44 46 48 49 4C 4E 50 51 52 53 54 55 BE | 8 | 0x00DF | RIF_PRESS_ASS | TSTREAMDATI | TAebVector | ack | 3A 3D 41 44 46 48 49 4C 4E 50 51 52 53 54 55 | [{"raw":58,"eng":58.0},{"raw":61,"eng":61.0},{"raw":65,"eng":65.0},{"raw":68,"eng":68.0},{"raw":70,"eng":70.0},{"raw":72,"eng":72.0},{"raw":73,"eng":73.0},{"raw":76,"eng":76.0},{"raw":78,"eng":78.0},{"raw":80,"eng":80.0},{"raw":81,"eng":81.0},{"raw":82,"eng":82.0},{"raw":83,"eng":83.0},{"raw":84,"eng":84.0},{"raw":85,"eng":85.0}] |
| 29 E0 00 09 | get_vector | 224.0 |  | 8 | True | 1 | 53 1E 00 00 8C 00 0E 01 CB 01 6D 02 33 03 1A 04 27 05 72 06 F7 07 D4 08 C4 09 DC 0A 1C 0C 5C 0D 5D | 8 | 0x00E0 | COEFF_PRESS_ASS | TSTREAMDATI | TAebVector | ack | 00 00 8C 00 0E 01 CB 01 6D 02 33 03 1A 04 27 05 72 06 F7 07 D4 08 C4 09 DC 0A 1C 0C 5C 0D | [{"raw":0,"eng":0.0},{"raw":140,"eng":140.0},{"raw":270,"eng":270.0},{"raw":459,"eng":459.0},{"raw":621,"eng":621.0},{"raw":819,"eng":819.0},{"raw":1050,"eng":1050.0},{"raw":1319,"eng":1319.0},{"raw":1650,"eng":1650.0},{"raw":2039,"eng":2039.0},{"raw":2260,"eng":2260.0},{"raw":2500,"eng":2500.0},{"raw":2780,"eng":2780.0},{"raw":3100,"eng":3100.0},{"raw":3420,"eng":3420.0}] |
| 29 E2 00 0B | get_vector | 226.0 |  | 8 | True | 1 | 53 08 00 00 00 00 00 00 00 00 5B | 8 | 0x00E2 | CHANGE_OVER_CILYNDER_DELAY | TSTREAMDATI | TAebVector | ack | 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 E3 00 0C | get_vector | 227.0 |  | 8 | True | 1 | 53 23 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 76 | 8 | 0x00E3 | FREST_PARAMETER_LR \| SERVICE_DATA | TSTREAMDATI | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 E7 00 10 | get_vector | 231.0 |  | 8 | True | 1 | 53 04 C3 F7 F7 F7 FF | 8 | 0x00E7 | ADVANCED_TEMP_RID | TSTREAMDATI | TAebVector | ack | C3 F7 F7 F7 | [{"raw":195,"eng":195.0},{"raw":247,"eng":247.0},{"raw":247,"eng":247.0},{"raw":247,"eng":247.0}] |
| 29 E8 00 11 | get_vector | 232.0 |  | 8 | True | 1 | 53 04 08 07 00 00 66 | 8 | 0x00E8 | ADVANCED_PRESS_BACK | TSTREAMDATI | TAebVector | ack | 08 07 00 00 | [{"raw":1800,"eng":1800.0},{"raw":0,"eng":0.0}] |
| 29 E9 00 12 | get_vector | 233.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x00E9 | SOGLIE_SESTANTI | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 ED 00 16 | get_vector | 237.0 |  | 8 | True | 1 | 53 03 00 00 FF 55 | 8 | 0x00ED | PARAMETRI_TAGLIANDI | TSTREAMDATI | TAebVector | ack | 00 00 FF | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":255,"eng":255.0}] |
| 29 EE 00 17 | get_vector | 238.0 |  | 8 | True | 1 | 53 02 00 32 87 | 8 | 0x00EE | TEMPI_ANTICIPI_EV | TSTREAMDATI | TAebVector | ack | 00 32 | [{"raw":0,"eng":0.0},{"raw":50,"eng":50.0}] |
| 29 F1 00 1A | get_vector | 241.0 |  | 8 | True | 1 | 53 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 2C 01 88 13 04 00 C3 00 FA | 8 | 0x00F1 | ADV_PARAM_INJ | TSTREAMDATI | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 2C 01 88 13 04 00 C3 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":300,"eng":300.0},{"raw":5000,"eng":5000.0},{"raw":4,"eng":4.0},{"raw":195,"eng":195.0}] |
| 29 F2 00 1B | get_vector | 242.0 |  | 8 | True | 1 | 53 0A 00 00 00 00 00 00 00 00 00 00 5D | 8 | 0x00F2 | ADV_OFFSET_INJ_PETROL | TSTRATEGIATEMPIMORTIDM | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 F3 00 1C | get_vector | 243.0 |  | 8 | True | 1 | 53 0A 00 00 00 00 00 00 00 00 00 00 5D | 8 | 0x00F3 | ADV_OFFSET_INJ_GAS | TSTRATEGIATEMPIMORTIDM | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 F8 00 21 | get_vector | 248.0 |  | 8 | True | 1 | 53 08 A8 00 04 00 50 46 10 0E BB | 8 | 0x00F8 | FLASH_LUBE_PARAMETER | TSTREAMDATI | TAebVector | ack | A8 00 04 00 50 46 10 0E | [{"raw":168,"eng":168.0},{"raw":4,"eng":4.0},{"raw":18000,"eng":18000.0},{"raw":3600,"eng":3600.0}] |
| 29 FA 00 23 | get_vector | 250.0 |  | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x00FA | FLAG_CONF3 | TSTREAMDATI | TAebVector | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 0C 01 36 | get_vector | 268.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x010C | TAGLIO_POMPA_BENZINA | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 29 0D 01 37 | get_vector | 269.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x010D | OBD_PARAMETER_PID | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 1C 00 45 | get_vector | 28.0 |  | 8 | True | 1 | 53 05 71 0B F0 05 00 C9 | 8 | 0x001C | ABIL_DIAGNOSI | TSTREAMDATI | TAebVector | ack | 71 0B F0 05 00 | [{"raw":113,"eng":113.0},{"raw":11,"eng":11.0},{"raw":240,"eng":240.0},{"raw":5,"eng":5.0},{"raw":0,"eng":0.0}] |
| 29 1D 00 46 | get_vector | 29.0 |  | 1124 | True | 1 | 53 05 00 00 00 00 00 58 | 1124 | 0x001D | STATO_DIAGNOSI | TSTREAMDATI | TAebVector | ack | 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 03 00 2C | get_vector | 3.0 |  | 16 | True | 1 | 53 04 86 24 51 10 62 | 16 | 0x0003 | FLAG_CONF1 | TSTREAMDATI | TAebVector | ack | 86 24 51 10 | [{"raw":9350,"eng":9350.0},{"raw":4177,"eng":4177.0}] |
| 29 2D 01 57 | get_vector | 301.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x012D | VH34_PARAM_INJ | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 32 01 5C | get_vector | 306.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0132 | WARMUP_PARAM_INJ | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 33 01 5D | get_vector | 307.0 |  | 8 | True | 1 | 53 0A 40 06 64 00 DC 05 02 00 14 00 FE | 8 | 0x0133 | ANTI_STALLO | TSTREAMDATI | TAebVector | ack | 40 06 64 00 DC 05 02 00 14 00 | [{"raw":1600,"eng":1600.0},{"raw":100,"eng":100.0},{"raw":1500,"eng":1500.0},{"raw":2,"eng":2.0},{"raw":20,"eng":20.0}] |
| 29 38 01 62 | get_vector | 312.0 |  | 8 | True | 1 | 53 14 20 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 8A | 8 | 0x0138 | PARAM_VARI | TSTREAMDATI | TAebVector | ack | 20 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":800,"eng":800.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 3C 01 66 | get_vector | 316.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x013C | INJR_TOFS_PTR_H | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4.00097656}] |
| 29 3D 01 67 | get_vector | 317.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x013D | INJR_TOFS_PTR_V | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4.00097656}] |
| 29 49 01 73 | get_vector | 329.0 |  | 10 | True | 1 | CA 01 10 DB | 10 | 0x0149 | EGEAR_RAT_BUF_INST | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 29 4B 01 75 | get_vector | 331.0 |  | 8 | True | 1 | 53 3C 00 01 00 02 00 03 00 04 00 05 00 06 00 07 00 08 00 09 00 0A 00 0B 00 0C 00 0D 00 0E 00 0F 00 10 00 11 00 12 00 13 00 14 00 16 00 18 00 1A 00 1C 00 1E 00 20 00 22 00 24 00 28 00 2C 9D | 8 | 0x014B | PETR_INJ_TBP | TAUTOCALDM | TAebVector | ack | 00 01 00 02 00 03 00 04 00 05 00 06 00 07 00 08 00 09 00 0A 00 0B 00 0C 00 0D 00 0E 00 0F 00 10 00 11 00 12 00 13 00 14 00 16 00 18 00 1A 00 1C 00 1E 00 20 00 22 00 24 00 28 00 2C | [{"raw":256,"eng":0.5},{"raw":512,"eng":1.0},{"raw":768,"eng":1.5},{"raw":1024,"eng":2.0},{"raw":1280,"eng":2.5},{"raw":1536,"eng":3.0},{"raw":1792,"eng":3.5},{"raw":2048,"eng":4.0},{"raw":2304,"eng":4.5},{"raw":2560,"eng":5.0},{"raw":2816,"eng":5.5},{"raw":3072,"eng":6.0},{"raw":3328,"eng":6.5},{"raw":3584,"eng":7.0},{"raw":3840,"eng":7.5},{"raw":4096,"eng":8.0},{"raw":4352,"eng":8.5},{"raw":4608,"eng":9.0},{"raw":4864,"eng":9.5},{"raw":5120,"eng":10.0},{"raw":5632,"eng":11.0},{"raw":6144,"eng":12.0},{"raw":6656,"eng":13.0},{"raw":7168,"eng":14.0},{"raw":7680,"eng":15.0},{"raw":8192,"eng":16.0},{"raw":8704,"eng":17.0},{"raw":9216,"eng":18.0},{"raw":10240,"eng":20.0},{"raw":11264,"eng":22.0}] |
| 29 4C 01 76 | get_vector | 332.0 |  | 8 | True | 1 | 53 24 9A 00 00 01 33 01 66 01 9A 01 CD 01 00 02 33 02 66 02 9A 02 CD 02 00 03 33 03 66 03 9A 03 CD 03 00 04 66 04 9D | 8 | 0x014C | MNFLD_PRESS_THD | TAUTOCALDM | TAebVector | ack | 9A 00 00 01 33 01 66 01 9A 01 CD 01 00 02 33 02 66 02 9A 02 CD 02 00 03 33 03 66 03 9A 03 CD 03 00 04 66 04 | [{"raw":154,"eng":0.15039062},{"raw":256,"eng":0.25},{"raw":307,"eng":0.29980469},{"raw":358,"eng":0.34960938},{"raw":410,"eng":0.40039062},{"raw":461,"eng":0.45019531},{"raw":512,"eng":0.5},{"raw":563,"eng":0.54980469},{"raw":614,"eng":0.59960938},{"raw":666,"eng":0.65039062},{"raw":717,"eng":0.70019531},{"raw":768,"eng":0.75},{"raw":819,"eng":0.79980469},{"raw":870,"eng":0.84960938},{"raw":922,"eng":0.90039062},{"raw":973,"eng":0.95019531},{"raw":1024,"eng":1.0},{"raw":1126,"eng":1.09960938}] |
| 29 4E 01 78 | get_vector | 334.0 |  | 8 | True | 1 | 53 24 00 00 00 00 00 00 00 00 00 00 00 00 44 09 7C 09 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 49 | 8 | 0x014E | PETR_INJ_TBUF_GAS_EE | TAUTOCALDM_EE | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 44 09 7C 09 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":2372,"eng":2372.0},{"raw":2428,"eng":2428.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 4F 01 79 | get_vector | 335.0 |  | 8 | True | 1 | 53 24 56 04 3C 05 C8 05 00 00 68 07 84 08 EC 08 7C 09 00 00 09 0C 00 00 5E 0E D1 13 F4 15 2C 18 54 18 00 00 00 00 71 | 8 | 0x014F | PETR_INJ_TBUF_GAS_PREV_EE | TAUTOCALDM_EE | TAebVector | ack | 56 04 3C 05 C8 05 00 00 68 07 84 08 EC 08 7C 09 00 00 09 0C 00 00 5E 0E D1 13 F4 15 2C 18 54 18 00 00 00 00 | [{"raw":1110,"eng":1110.0},{"raw":1340,"eng":1340.0},{"raw":1480,"eng":1480.0},{"raw":0,"eng":0.0},{"raw":1896,"eng":1896.0},{"raw":2180,"eng":2180.0},{"raw":2284,"eng":2284.0},{"raw":2428,"eng":2428.0},{"raw":0,"eng":0.0},{"raw":3081,"eng":3081.0},{"raw":0,"eng":0.0},{"raw":3678,"eng":3678.0},{"raw":5073,"eng":5073.0},{"raw":5620,"eng":5620.0},{"raw":6188,"eng":6188.0},{"raw":6228,"eng":6228.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 50 01 7A | get_vector | 336.0 |  | 8 | True | 1 | 53 24 00 00 92 05 1D 06 09 07 91 07 32 08 D1 08 B3 09 72 0A 2B 0C 58 0D 75 0F 30 14 64 15 00 00 95 19 00 00 00 00 AF | 8 | 0x0150 | PETR_INJ_TBUF_PETR_EE | TAUTOCALDM_EE | TAebVector | ack | 00 00 92 05 1D 06 09 07 91 07 32 08 D1 08 B3 09 72 0A 2B 0C 58 0D 75 0F 30 14 64 15 00 00 95 19 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":1426,"eng":1426.0},{"raw":1565,"eng":1565.0},{"raw":1801,"eng":1801.0},{"raw":1937,"eng":1937.0},{"raw":2098,"eng":2098.0},{"raw":2257,"eng":2257.0},{"raw":2483,"eng":2483.0},{"raw":2674,"eng":2674.0},{"raw":3115,"eng":3115.0},{"raw":3416,"eng":3416.0},{"raw":3957,"eng":3957.0},{"raw":5168,"eng":5168.0},{"raw":5476,"eng":5476.0},{"raw":0,"eng":0.0},{"raw":6549,"eng":6549.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 51 01 7B | get_vector | 337.0 |  | 8 | True | 1 | 53 24 00 00 00 00 00 00 00 00 00 00 00 00 2E 02 40 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 E9 | 8 | 0x0151 | MNFLD_PRESS_BUF_GAS_EE | TAUTOCALDM_EE | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 2E 02 40 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":558,"eng":558.0},{"raw":576,"eng":576.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 52 01 7C | get_vector | 338.0 |  | 8 | True | 1 | 53 24 EE 00 19 01 34 01 00 00 A8 01 FD 01 1A 02 38 02 00 00 B8 02 00 00 10 03 48 03 84 03 CC 03 EC 03 00 00 00 00 0E | 8 | 0x0152 | MNFLD_PRESS_BUF_GAS_PREV_EE | TAUTOCALDM_EE | TAebVector | ack | EE 00 19 01 34 01 00 00 A8 01 FD 01 1A 02 38 02 00 00 B8 02 00 00 10 03 48 03 84 03 CC 03 EC 03 00 00 00 00 | [{"raw":238,"eng":238.0},{"raw":281,"eng":281.0},{"raw":308,"eng":308.0},{"raw":0,"eng":0.0},{"raw":424,"eng":424.0},{"raw":509,"eng":509.0},{"raw":538,"eng":538.0},{"raw":568,"eng":568.0},{"raw":0,"eng":0.0},{"raw":696,"eng":696.0},{"raw":0,"eng":0.0},{"raw":784,"eng":784.0},{"raw":840,"eng":840.0},{"raw":900,"eng":900.0},{"raw":972,"eng":972.0},{"raw":1004,"eng":1004.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 53 01 7D | get_vector | 339.0 |  | 8 | True | 1 | 53 24 00 00 1A 01 49 01 72 01 AD 01 E1 01 0B 02 49 02 78 02 C8 02 E5 02 1D 03 50 03 7D 03 00 00 EF 03 00 00 00 00 47 | 8 | 0x0153 | MNFLD_PRESS_BUF_PETR_EE | TAUTOCALDM_EE | TAebVector | ack | 00 00 1A 01 49 01 72 01 AD 01 E1 01 0B 02 49 02 78 02 C8 02 E5 02 1D 03 50 03 7D 03 00 00 EF 03 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":282,"eng":282.0},{"raw":329,"eng":329.0},{"raw":370,"eng":370.0},{"raw":429,"eng":429.0},{"raw":481,"eng":481.0},{"raw":523,"eng":523.0},{"raw":585,"eng":585.0},{"raw":632,"eng":632.0},{"raw":712,"eng":712.0},{"raw":741,"eng":741.0},{"raw":797,"eng":797.0},{"raw":848,"eng":848.0},{"raw":893,"eng":893.0},{"raw":0,"eng":0.0},{"raw":1007,"eng":1007.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 54 01 7E | get_vector | 340.0 |  | 8 | True | 1 | 53 24 00 00 00 00 00 00 00 00 00 00 00 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 79 | 8 | 0x0154 | BUF_UPD_GAS_EE | TAUTOCALDM_EE | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":1,"eng":1.0},{"raw":1,"eng":1.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 55 01 7F | get_vector | 341.0 |  | 8 | True | 1 | 53 24 00 00 04 00 02 00 04 00 03 00 04 00 02 00 09 00 05 00 08 00 05 00 05 00 01 00 04 00 00 00 01 00 00 00 00 00 B0 | 8 | 0x0155 | BUF_UPD_PETR_EE | TAUTOCALDM_EE | TAebVector | ack | 00 00 04 00 02 00 04 00 03 00 04 00 02 00 09 00 05 00 08 00 05 00 05 00 01 00 04 00 00 00 01 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":4,"eng":4.0},{"raw":2,"eng":2.0},{"raw":4,"eng":4.0},{"raw":3,"eng":3.0},{"raw":4,"eng":4.0},{"raw":2,"eng":2.0},{"raw":9,"eng":9.0},{"raw":5,"eng":5.0},{"raw":8,"eng":8.0},{"raw":5,"eng":5.0},{"raw":5,"eng":5.0},{"raw":1,"eng":1.0},{"raw":4,"eng":4.0},{"raw":0,"eng":0.0},{"raw":1,"eng":1.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 56 01 80 | get_vector | 342.0 |  | 8 | True | 1 | 53 06 00 00 00 00 00 00 59 | 8 | 0x0156 | VECT_EE_S16 | TAUTOCALDM_EE | TAebVector | ack | 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 57 01 81 | get_vector | 343.0 |  | 8 | True | 1 | 53 06 00 00 00 00 00 00 59 | 8 | 0x0157 | VECT_EE_U16 | TAUTOCALDM_EE | TAebVector | ack | 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 58 01 82 | get_vector | 344.0 |  | 8 | True | 1 | 53 3C 5E 32 5E 32 5E 32 5E 32 5E 32 5E 32 42 38 F2 3A 6A 3C 6F 42 AA 41 2F 45 98 3E FA 3E 98 3E E9 3E 87 3E 83 40 02 43 8F 42 0E 45 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 75 | 8 | 0x0158 | MUL_ACT_EE | TAUTOCALDM_EE | TAebVector | ack | 5E 32 5E 32 5E 32 5E 32 5E 32 5E 32 42 38 F2 3A 6A 3C 6F 42 AA 41 2F 45 98 3E FA 3E 98 3E E9 3E 87 3E 83 40 02 43 8F 42 0E 45 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 | [{"raw":12894,"eng":12894.0},{"raw":12894,"eng":12894.0},{"raw":12894,"eng":12894.0},{"raw":12894,"eng":12894.0},{"raw":12894,"eng":12894.0},{"raw":12894,"eng":12894.0},{"raw":14402,"eng":14402.0},{"raw":15090,"eng":15090.0},{"raw":15466,"eng":15466.0},{"raw":17007,"eng":17007.0},{"raw":16810,"eng":16810.0},{"raw":17711,"eng":17711.0},{"raw":16024,"eng":16024.0},{"raw":16122,"eng":16122.0},{"raw":16024,"eng":16024.0},{"raw":16105,"eng":16105.0},{"raw":16007,"eng":16007.0},{"raw":16515,"eng":16515.0},{"raw":17154,"eng":17154.0},{"raw":17039,"eng":17039.0},{"raw":17678,"eng":17678.0},{"raw":18678,"eng":18678.0},{"raw":18678,"eng":18678.0},{"raw":18678,"eng":18678.0},{"raw":18678,"eng":18678.0},{"raw":18678,"eng":18678.0},{"raw":18678,"eng":18678.0},{"raw":18678,"eng":18678.0},{"raw":18678,"eng":18678.0},{"raw":18678,"eng":18678.0}] |
| 29 59 01 83 | get_vector | 345.0 |  | 8 | True | 1 | 53 3C 15 41 15 41 15 41 15 41 15 41 15 41 D2 3E E0 3C 23 3F 26 41 C0 3F 85 42 4E 40 6D 3F 84 3E B8 40 AD 40 B5 40 CA 40 00 40 A2 40 08 3F 08 3F 08 3F 08 3F 08 3F 08 3F 08 3F 08 3F 08 3F CF | 8 | 0x0159 | MUL_PREV_EE | TAUTOCALDM_EE | TAebVector | ack | 15 41 15 41 15 41 15 41 15 41 15 41 D2 3E E0 3C 23 3F 26 41 C0 3F 85 42 4E 40 6D 3F 84 3E B8 40 AD 40 B5 40 CA 40 00 40 A2 40 08 3F 08 3F 08 3F 08 3F 08 3F 08 3F 08 3F 08 3F 08 3F | [{"raw":16661,"eng":16661.0},{"raw":16661,"eng":16661.0},{"raw":16661,"eng":16661.0},{"raw":16661,"eng":16661.0},{"raw":16661,"eng":16661.0},{"raw":16661,"eng":16661.0},{"raw":16082,"eng":16082.0},{"raw":15584,"eng":15584.0},{"raw":16163,"eng":16163.0},{"raw":16678,"eng":16678.0},{"raw":16320,"eng":16320.0},{"raw":17029,"eng":17029.0},{"raw":16462,"eng":16462.0},{"raw":16237,"eng":16237.0},{"raw":16004,"eng":16004.0},{"raw":16568,"eng":16568.0},{"raw":16557,"eng":16557.0},{"raw":16565,"eng":16565.0},{"raw":16586,"eng":16586.0},{"raw":16384,"eng":16384.0},{"raw":16546,"eng":16546.0},{"raw":16136,"eng":16136.0},{"raw":16136,"eng":16136.0},{"raw":16136,"eng":16136.0},{"raw":16136,"eng":16136.0},{"raw":16136,"eng":16136.0},{"raw":16136,"eng":16136.0},{"raw":16136,"eng":16136.0},{"raw":16136,"eng":16136.0},{"raw":16136,"eng":16136.0}] |
| 29 5B 01 85 | get_vector | 347.0 |  | 16 | True | 1 | 53 24 00 00 04 00 02 00 04 00 03 00 04 00 02 00 09 00 05 00 08 00 05 00 05 00 01 00 04 00 00 00 01 00 00 00 00 00 B0 | 16 | 0x015B | NUM_BUF_UPD_PETR | TAUTOCALDM | TAebVector | ack | 00 00 04 00 02 00 04 00 03 00 04 00 02 00 09 00 05 00 08 00 05 00 05 00 01 00 04 00 00 00 01 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":4,"eng":4.0},{"raw":2,"eng":2.0},{"raw":4,"eng":4.0},{"raw":3,"eng":3.0},{"raw":4,"eng":4.0},{"raw":2,"eng":2.0},{"raw":9,"eng":9.0},{"raw":5,"eng":5.0},{"raw":8,"eng":8.0},{"raw":5,"eng":5.0},{"raw":5,"eng":5.0},{"raw":1,"eng":1.0},{"raw":4,"eng":4.0},{"raw":0,"eng":0.0},{"raw":1,"eng":1.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 5C 01 86 | get_vector | 348.0 |  | 17 | True | 1 | 53 24 00 00 00 00 00 00 00 00 00 00 00 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 79 | 17 | 0x015C | NUM_BUF_UPD_GAS | TAUTOCALDM | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":1,"eng":1.0},{"raw":1,"eng":1.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 5D 01 87 | get_vector | 349.0 |  | 16 | True | 1 | 53 24 56 04 3C 05 C8 05 00 00 68 07 84 08 EC 08 7C 09 00 00 09 0C 00 00 5E 0E D1 13 F4 15 2C 18 54 18 00 00 00 00 71 | 16 | 0x015D | PETR_INJ_TBUF_GAS_PREV | TAUTOCALDM | TAebVector | ack | 56 04 3C 05 C8 05 00 00 68 07 84 08 EC 08 7C 09 00 00 09 0C 00 00 5E 0E D1 13 F4 15 2C 18 54 18 00 00 00 00 | [{"raw":1110,"eng":2.16796875},{"raw":1340,"eng":2.6171875},{"raw":1480,"eng":2.890625},{"raw":0,"eng":0.0},{"raw":1896,"eng":3.703125},{"raw":2180,"eng":4.2578125},{"raw":2284,"eng":4.4609375},{"raw":2428,"eng":4.7421875},{"raw":0,"eng":0.0},{"raw":3081,"eng":6.01757812},{"raw":0,"eng":0.0},{"raw":3678,"eng":7.18359375},{"raw":5073,"eng":9.90820312},{"raw":5620,"eng":10.9765625},{"raw":6188,"eng":12.0859375},{"raw":6228,"eng":12.1640625},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 5E 01 88 | get_vector | 350.0 |  | 16 | True | 1 | 53 24 EE 00 19 01 34 01 00 00 A8 01 FD 01 1A 02 38 02 00 00 B8 02 00 00 10 03 48 03 84 03 CC 03 EC 03 00 00 00 00 0E | 16 | 0x015E | MNFLD_PRESS_BUF_GAS_PREV | TAUTOCALDM | TAebVector | ack | EE 00 19 01 34 01 00 00 A8 01 FD 01 1A 02 38 02 00 00 B8 02 00 00 10 03 48 03 84 03 CC 03 EC 03 00 00 00 00 | [{"raw":238,"eng":0.23242188},{"raw":281,"eng":0.27441406},{"raw":308,"eng":0.30078125},{"raw":0,"eng":0.0},{"raw":424,"eng":0.4140625},{"raw":509,"eng":0.49707031},{"raw":538,"eng":0.52539062},{"raw":568,"eng":0.5546875},{"raw":0,"eng":0.0},{"raw":696,"eng":0.6796875},{"raw":0,"eng":0.0},{"raw":784,"eng":0.765625},{"raw":840,"eng":0.8203125},{"raw":900,"eng":0.87890625},{"raw":972,"eng":0.94921875},{"raw":1004,"eng":0.98046875},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 5F 01 89 | get_vector | 351.0 |  | 17 | True | 1 | 53 24 00 00 00 00 00 00 00 00 00 00 00 00 44 09 7C 09 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 49 | 17 | 0x015F | PETR_INJ_TBUF_GAS | TAUTOCALDM | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 44 09 7C 09 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":2372,"eng":4.6328125},{"raw":2428,"eng":4.7421875},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 60 01 8A | get_vector | 352.0 |  | 17 | True | 1 | 53 24 00 00 00 00 00 00 00 00 00 00 00 00 2E 02 40 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 E9 | 17 | 0x0160 | MNFLD_PRESS_BUF_GAS | TAUTOCALDM | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 2E 02 40 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":558,"eng":0.54492188},{"raw":576,"eng":0.5625},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 61 01 8B | get_vector | 353.0 |  | 15 | True | 1 | 53 3C 5E 32 5E 32 5E 32 5E 32 5E 32 5E 32 42 38 F2 3A 6A 3C 6F 42 AA 41 2F 45 98 3E FA 3E 98 3E E9 3E 87 3E 83 40 02 43 8F 42 0E 45 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 75 | 15 | 0x0161 | MUL_ACT | TAUTOCALDM | TAebVector | ack | 5E 32 5E 32 5E 32 5E 32 5E 32 5E 32 42 38 F2 3A 6A 3C 6F 42 AA 41 2F 45 98 3E FA 3E 98 3E E9 3E 87 3E 83 40 02 43 8F 42 0E 45 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 F6 48 | [{"raw":12894,"eng":0.7869873},{"raw":12894,"eng":0.7869873},{"raw":12894,"eng":0.7869873},{"raw":12894,"eng":0.7869873},{"raw":12894,"eng":0.7869873},{"raw":12894,"eng":0.7869873},{"raw":14402,"eng":0.87902832},{"raw":15090,"eng":0.92102051},{"raw":15466,"eng":0.94396973},{"raw":17007,"eng":1.0380249},{"raw":16810,"eng":1.02600098},{"raw":17711,"eng":1.08099365},{"raw":16024,"eng":0.97802734},{"raw":16122,"eng":0.98400879},{"raw":16024,"eng":0.97802734},{"raw":16105,"eng":0.98297119},{"raw":16007,"eng":0.97698975},{"raw":16515,"eng":1.00799561},{"raw":17154,"eng":1.04699707},{"raw":17039,"eng":1.03997803},{"raw":17678,"eng":1.07897949},{"raw":18678,"eng":1.14001465},{"raw":18678,"eng":1.14001465},{"raw":18678,"eng":1.14001465},{"raw":18678,"eng":1.14001465},{"raw":18678,"eng":1.14001465},{"raw":18678,"eng":1.14001465},{"raw":18678,"eng":1.14001465},{"raw":18678,"eng":1.14001465},{"raw":18678,"eng":1.14001465}] |
| 29 62 01 8C | get_vector | 354.0 |  | 16 | True | 1 | 53 24 00 00 92 05 1D 06 09 07 91 07 32 08 D1 08 B3 09 72 0A 2B 0C 58 0D 75 0F 30 14 64 15 00 00 95 19 00 00 00 00 AF | 16 | 0x0162 | PETR_INJ_TBUF | TAUTOCALDM \| TSTREAMDATI | TAebVector | ack | 00 00 92 05 1D 06 09 07 91 07 32 08 D1 08 B3 09 72 0A 2B 0C 58 0D 75 0F 30 14 64 15 00 00 95 19 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":1426,"eng":2.78515625},{"raw":1565,"eng":3.05664062},{"raw":1801,"eng":3.51757812},{"raw":1937,"eng":3.78320312},{"raw":2098,"eng":4.09765625},{"raw":2257,"eng":4.40820312},{"raw":2483,"eng":4.84960938},{"raw":2674,"eng":5.22265625},{"raw":3115,"eng":6.08398438},{"raw":3416,"eng":6.671875},{"raw":3957,"eng":7.72851562},{"raw":5168,"eng":10.09375},{"raw":5476,"eng":10.6953125},{"raw":0,"eng":0.0},{"raw":6549,"eng":12.79101562},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 63 01 8D | get_vector | 355.0 |  | 16 | True | 1 | 53 24 00 00 1A 01 49 01 72 01 AD 01 E1 01 0B 02 49 02 78 02 C8 02 E5 02 1D 03 50 03 7D 03 00 00 EF 03 00 00 00 00 47 | 16 | 0x0163 | MNFLD_PRESS_BUF | TAUTOCALDM | TAebVector | ack | 00 00 1A 01 49 01 72 01 AD 01 E1 01 0B 02 49 02 78 02 C8 02 E5 02 1D 03 50 03 7D 03 00 00 EF 03 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":282,"eng":0.27539062},{"raw":329,"eng":0.32128906},{"raw":370,"eng":0.36132812},{"raw":429,"eng":0.41894531},{"raw":481,"eng":0.46972656},{"raw":523,"eng":0.51074219},{"raw":585,"eng":0.57128906},{"raw":632,"eng":0.6171875},{"raw":712,"eng":0.6953125},{"raw":741,"eng":0.72363281},{"raw":797,"eng":0.77832031},{"raw":848,"eng":0.828125},{"raw":893,"eng":0.87207031},{"raw":0,"eng":0.0},{"raw":1007,"eng":0.98339844},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 64 01 8E | get_vector | 356.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0164 | VECT_AUTOCAL_EE | TAUTOCALDM_EE | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 29 6F 01 99 | get_vector | 367.0 |  | 5 | True | 1 | 53 04 00 00 00 00 57 | 5 | 0x016F | ACQUIRED_ZONES_PETROL | TAUTOCALDM | TAebVector | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 70 01 9A | get_vector | 368.0 |  | 2 | True | 1 | 53 04 00 00 00 00 57 | 2 | 0x0170 | ACQUIRED_ZONES_GAS | TAUTOCALDM | TAebVector | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 25 00 4E | get_vector | 37.0 |  | 8 | True | 1 | 53 04 27 5D 8F DB 45 | 8 | 0x0025 | RIF_SENSORE | TSTREAMDATI | TAebVector | ack | 27 5D 8F DB | [{"raw":39,"eng":39.0},{"raw":93,"eng":93.0},{"raw":143,"eng":143.0},{"raw":219,"eng":219.0}] |
| 29 72 01 9C | get_vector | 370.0 |  | 8 | True | 1 | 53 0A 01 03 03 01 03 03 01 03 03 01 73 | 8 | 0x0172 | CALIBRATION_VAL_1 | TAUTOCALDM | TAebVector | ack | 01 03 03 01 03 03 01 03 03 01 | [{"raw":1,"eng":1.0},{"raw":3,"eng":3.0},{"raw":3,"eng":3.0},{"raw":1,"eng":1.0},{"raw":3,"eng":3.0},{"raw":3,"eng":3.0},{"raw":1,"eng":1.0},{"raw":3,"eng":3.0},{"raw":3,"eng":3.0},{"raw":1,"eng":1.0}] |
| 29 79 01 A3 | get_vector | 377.0 |  | 8 | True | 1 | 53 05 FF FF FF FF FF 53 | 8 | 0x0179 | ABIL_FREEZEFRAME | TSTREAMDATI | TAebVector | ack | FF FF FF FF FF | [{"raw":255,"eng":255.0},{"raw":255,"eng":255.0},{"raw":255,"eng":255.0},{"raw":255,"eng":255.0},{"raw":255,"eng":255.0}] |
| 29 26 00 4F | get_vector | 38.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0026 | GIRI_ANTICIPO | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 29 27 00 50 | get_vector | 39.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x0027 | COEFF_ANTICIPO | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 8D 01 B7 | get_vector | 397.0 |  | 6 | True | 1 | 53 3C 0A 00 2D 00 71 00 B6 00 FB 00 3F 01 83 01 C8 01 12 02 4E 02 85 02 C7 02 DE 02 F8 02 0D 03 22 03 2D 03 38 03 45 03 55 03 8E 03 C1 03 F4 03 27 04 5A 04 8D 04 C0 04 F3 04 59 05 BF 05 86 | 6 | 0x018D | PETR_MNFLD_PRESS_RV | TAUTOCALDM | TAebVector | ack | 0A 00 2D 00 71 00 B6 00 FB 00 3F 01 83 01 C8 01 12 02 4E 02 85 02 C7 02 DE 02 F8 02 0D 03 22 03 2D 03 38 03 45 03 55 03 8E 03 C1 03 F4 03 27 04 5A 04 8D 04 C0 04 F3 04 59 05 BF 05 | [{"raw":10,"eng":0.00976562},{"raw":45,"eng":0.04394531},{"raw":113,"eng":0.11035156},{"raw":182,"eng":0.17773438},{"raw":251,"eng":0.24511719},{"raw":319,"eng":0.31152344},{"raw":387,"eng":0.37792969},{"raw":456,"eng":0.4453125},{"raw":530,"eng":0.51757812},{"raw":590,"eng":0.57617188},{"raw":645,"eng":0.62988281},{"raw":711,"eng":0.69433594},{"raw":734,"eng":0.71679688},{"raw":760,"eng":0.7421875},{"raw":781,"eng":0.76269531},{"raw":802,"eng":0.78320312},{"raw":813,"eng":0.79394531},{"raw":824,"eng":0.8046875},{"raw":837,"eng":0.81738281},{"raw":853,"eng":0.83300781},{"raw":910,"eng":0.88867188},{"raw":961,"eng":0.93847656},{"raw":1012,"eng":0.98828125},{"raw":1063,"eng":1.03808594},{"raw":1114,"eng":1.08789062},{"raw":1165,"eng":1.13769531},{"raw":1216,"eng":1.1875},{"raw":1267,"eng":1.23730469},{"raw":1369,"eng":1.33691406},{"raw":1471,"eng":1.43652344}] |
| 29 8E 01 B8 | get_vector | 398.0 |  | 6 | True | 1 | 53 3C 4E 00 7E 00 AE 00 DE 00 0E 01 36 01 8E 01 ED 01 17 02 41 02 88 02 B4 02 DC 02 FC 02 16 03 20 03 2B 03 36 03 40 03 55 03 86 03 CE 03 16 04 5E 04 A6 04 EE 04 36 05 7E 05 0E 06 9E 06 48 | 6 | 0x018E | GAS_MNFLD_PRESS_RV | TAUTOCALDM | TAebVector | ack | 4E 00 7E 00 AE 00 DE 00 0E 01 36 01 8E 01 ED 01 17 02 41 02 88 02 B4 02 DC 02 FC 02 16 03 20 03 2B 03 36 03 40 03 55 03 86 03 CE 03 16 04 5E 04 A6 04 EE 04 36 05 7E 05 0E 06 9E 06 | [{"raw":78,"eng":0.07617188},{"raw":126,"eng":0.12304688},{"raw":174,"eng":0.16992188},{"raw":222,"eng":0.21679688},{"raw":270,"eng":0.26367188},{"raw":310,"eng":0.30273438},{"raw":398,"eng":0.38867188},{"raw":493,"eng":0.48144531},{"raw":535,"eng":0.52246094},{"raw":577,"eng":0.56347656},{"raw":648,"eng":0.6328125},{"raw":692,"eng":0.67578125},{"raw":732,"eng":0.71484375},{"raw":764,"eng":0.74609375},{"raw":790,"eng":0.77148438},{"raw":800,"eng":0.78125},{"raw":811,"eng":0.79199219},{"raw":822,"eng":0.80273438},{"raw":832,"eng":0.8125},{"raw":853,"eng":0.83300781},{"raw":902,"eng":0.88085938},{"raw":974,"eng":0.95117188},{"raw":1046,"eng":1.02148438},{"raw":1118,"eng":1.09179688},{"raw":1190,"eng":1.16210938},{"raw":1262,"eng":1.23242188},{"raw":1334,"eng":1.30273438},{"raw":1406,"eng":1.37304688},{"raw":1550,"eng":1.51367188},{"raw":1694,"eng":1.65429688}] |
| 29 9E 01 C8 | get_vector | 414.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x019E | PARAMETRI_EXTRA_INJ | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 29 2A 00 53 | get_vector | 42.0 |  | 8 | True | 1 | 53 0A 00 26 32 3A 43 4D 53 58 64 FF 8D | 8 | 0x002A | RIF_TEMP_GAS_LR \| RIF_TEMP_RID | TSTREAMDATI | TAebVector | ack | 00 26 32 3A 43 4D 53 58 64 FF | [{"raw":0,"eng":0.0},{"raw":38,"eng":38.0},{"raw":50,"eng":50.0},{"raw":58,"eng":58.0},{"raw":67,"eng":67.0},{"raw":77,"eng":77.0},{"raw":83,"eng":83.0},{"raw":88,"eng":88.0},{"raw":100,"eng":100.0},{"raw":255,"eng":255.0}] |
| 29 2B 00 54 | get_vector | 43.0 |  | 8 | True | 1 | 53 09 64 63 61 5E 5B 59 56 52 50 8E | 8 | 0x002B | COEFF_TEMP_GAS_LR \| COEFF_TEMP_RID | TSTREAMDATI | TAebVector | ack | 64 63 61 5E 5B 59 56 52 50 | [{"raw":100,"eng":100.0},{"raw":99,"eng":99.0},{"raw":97,"eng":97.0},{"raw":94,"eng":94.0},{"raw":91,"eng":91.0},{"raw":89,"eng":89.0},{"raw":86,"eng":86.0},{"raw":82,"eng":82.0},{"raw":80,"eng":80.0}] |
| 29 2D 00 56 | get_vector | 45.0 |  | 8 | True | 1 | CA 01 10 DB | 8 | 0x002D | MAP_ANTICIPO | TSTREAMDATI | TAebVector | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 29 2F 00 58 | get_vector | 47.0 |  | 8 | True | 1 | 53 09 E7 D7 C3 B6 A9 9B 8D 71 58 2D | 8 | 0x002F | RIF_DELAY_GAS_TEMP | TSTREAMDATI | TAebVector | ack | E7 D7 C3 B6 A9 9B 8D 71 58 | [{"raw":231,"eng":231.0},{"raw":215,"eng":215.0},{"raw":195,"eng":195.0},{"raw":182,"eng":182.0},{"raw":169,"eng":169.0},{"raw":155,"eng":155.0},{"raw":141,"eng":141.0},{"raw":113,"eng":113.0},{"raw":88,"eng":88.0}] |
| 29 32 00 5B | get_vector | 50.0 |  | 8 | True | 1 | 53 04 00 00 D1 03 2B | 8 | 0x0032 | GIRI_CUTOFF_LR \| GIRI_TEMPO_CUTOFF | TSTREAMDATI | TAebNumber \| TAebVector | ack | 00 00 D1 03 | [{"raw":0,"eng":0.0},{"raw":977,"eng":977.0}] |
| 29 35 00 5E | get_vector | 53.0 |  | 8 | True | 2 | 53 1E 00 00 32 30 38 20 53 48 45 4C 20 6C 61 75 72 6F 20 00 00 00 00 00 00 00 00 00 00 00 00 00 BA | 7 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack | 00 00 32 30 38 20 53 48 45 4C 20 6C 61 75 72 6F 20 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":50,"eng":50.0},{"raw":48,"eng":48.0},{"raw":56,"eng":56.0},{"raw":32,"eng":32.0},{"raw":83,"eng":83.0},{"raw":72,"eng":72.0},{"raw":69,"eng":69.0},{"raw":76,"eng":76.0},{"raw":32,"eng":32.0},{"raw":108,"eng":108.0},{"raw":97,"eng":97.0},{"raw":117,"eng":117.0},{"raw":114,"eng":114.0},{"raw":111,"eng":111.0},{"raw":32,"eng":32.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 29 37 00 60 | get_vector | 55.0 |  | 8 | True | 1 | 53 18 0D 03 D1 03 94 04 57 05 DE 06 28 09 35 0C 42 0F 4F 12 5D 15 6A 18 77 1B D1 | 8 | 0x0037 | TEMPI_PER_K | TSTREAMDATI | TAebVector | ack | 0D 03 D1 03 94 04 57 05 DE 06 28 09 35 0C 42 0F 4F 12 5D 15 6A 18 77 1B | [{"raw":781,"eng":781.0},{"raw":977,"eng":977.0},{"raw":1172,"eng":1172.0},{"raw":1367,"eng":1367.0},{"raw":1758,"eng":1758.0},{"raw":2344,"eng":2344.0},{"raw":3125,"eng":3125.0},{"raw":3906,"eng":3906.0},{"raw":4687,"eng":4687.0},{"raw":5469,"eng":5469.0},{"raw":6250,"eng":6250.0},{"raw":7031,"eng":7031.0}] |
| 29 3D 00 66 | get_vector | 61.0 |  | 8 | True | 1 | 53 18 52 03 46 05 3A 07 C4 09 B8 0B AC 0D A0 0F 94 11 88 13 7C 15 70 17 64 19 19 | 8 | 0x003D | GIRI_PER_K | TSTREAMDATI | TAebVector | ack | 52 03 46 05 3A 07 C4 09 B8 0B AC 0D A0 0F 94 11 88 13 7C 15 70 17 64 19 | [{"raw":850,"eng":850.0},{"raw":1350,"eng":1350.0},{"raw":1850,"eng":1850.0},{"raw":2500,"eng":2500.0},{"raw":3000,"eng":3000.0},{"raw":3500,"eng":3500.0},{"raw":4000,"eng":4000.0},{"raw":4500,"eng":4500.0},{"raw":5000,"eng":5000.0},{"raw":5500,"eng":5500.0},{"raw":6000,"eng":6000.0},{"raw":6500,"eng":6500.0}] |
| 29 4A 00 73 | get_vector | 74.0 |  | 8 | True | 1 | 53 04 A1 07 00 00 FF | 8 | 0x004A | TEMPO_MAX_CORRENTE | TSTREAMDATI | TAebVector | ack | A1 07 00 00 | [{"raw":1953,"eng":1953.0},{"raw":0,"eng":0.0}] |
| 29 51 00 7A | get_vector | 81.0 |  | 8 | True | 1 | 53 04 F7 02 E0 02 32 | 8 | 0x0051 | TEMP_DIAGNOSI | TSTREAMDATI | TAebVector | ack | F7 02 E0 02 | [{"raw":247,"eng":247.0},{"raw":2,"eng":2.0},{"raw":224,"eng":224.0},{"raw":2,"eng":2.0}] |
| 29 56 00 7F | get_vector | 86.0 |  | 2 | True | 1 | 53 06 ED 02 57 04 A9 02 4E | 2 | 0x0056 | TEMPI_SECONDI | TSTREAMDATI | TAebVector | ack | ED 02 57 04 A9 02 | [{"raw":749,"eng":749.0},{"raw":1111,"eng":1111.0},{"raw":681,"eng":681.0}] |
| 29 5C 00 85 | get_vector | 92.0 |  | 8 | True | 1 | 53 0A 00 18 26 32 43 58 71 9B C3 FF 36 | 8 | 0x005C | RIF_TEMP_GAS \| RIF_TEMP_RID_LR | TSTREAMDATI | TAebVector | ack | 00 18 26 32 43 58 71 9B C3 FF | [{"raw":0,"eng":0.0},{"raw":24,"eng":24.0},{"raw":38,"eng":38.0},{"raw":50,"eng":50.0},{"raw":67,"eng":67.0},{"raw":88,"eng":88.0},{"raw":113,"eng":113.0},{"raw":155,"eng":155.0},{"raw":195,"eng":195.0},{"raw":255,"eng":255.0}] |
| 29 5D 00 86 | get_vector | 93.0 |  | 8 | True | 1 | 53 09 6B 69 67 65 64 62 61 5E 5C DD | 8 | 0x005D | COEFF_TEMP_GAS \| COEFF_TEMP_RID_LR | TSTREAMDATI | TAebVector | ack | 6B 69 67 65 64 62 61 5E 5C | [{"raw":107,"eng":107.0},{"raw":105,"eng":105.0},{"raw":103,"eng":103.0},{"raw":101,"eng":101.0},{"raw":100,"eng":100.0},{"raw":98,"eng":98.0},{"raw":97,"eng":97.0},{"raw":94,"eng":94.0},{"raw":92,"eng":92.0}] |
| 29 5F 00 88 | get_vector | 95.0 |  | 8 | True | 1 | 53 1E 2B 01 90 01 F4 01 57 02 BB 02 20 03 84 03 E8 03 4C 04 AF 04 14 05 77 05 DC 05 40 06 A3 06 36 | 8 | 0x005F | RIF_PRESS_COLL | TSTREAMDATI | TAebVector | ack | 2B 01 90 01 F4 01 57 02 BB 02 20 03 84 03 E8 03 4C 04 AF 04 14 05 77 05 DC 05 40 06 A3 06 | [{"raw":299,"eng":299.0},{"raw":400,"eng":400.0},{"raw":500,"eng":500.0},{"raw":599,"eng":599.0},{"raw":699,"eng":699.0},{"raw":800,"eng":800.0},{"raw":900,"eng":900.0},{"raw":1000,"eng":1000.0},{"raw":1100,"eng":1100.0},{"raw":1199,"eng":1199.0},{"raw":1300,"eng":1300.0},{"raw":1399,"eng":1399.0},{"raw":1500,"eng":1500.0},{"raw":1600,"eng":1600.0},{"raw":1699,"eng":1699.0}] |
| 29 60 00 89 | get_vector | 96.0 |  | 8 | True | 1 | 53 1E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 71 | 8 | 0x0060 | COEFF_PRESS_COLL | TSTREAMDATI | TAebVector | ack | 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 67 00 00 91 | get_vector_indexed | 103.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x0067 | MAP_DELAY_LAMBDA \| PRESS_RETROPASSAGGIO_LR | TSTREAMDATI | TAebMatrix \| TAebVector | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 2A 70 00 00 9A | get_vector_indexed | 112.0 | 00 | 8 | True | 1 | 53 0C 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 97 | 8 | 0x0070 | MAP_RIF_SONDA_LAMBDA \| RIF_GIRI_BENZINA_LR | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A | [{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0}] |
| 2A 70 00 01 9B | get_vector_indexed | 112.0 | 01 | 8 | True | 1 | 53 0C 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 97 | 8 | 0x0070 | MAP_RIF_SONDA_LAMBDA \| RIF_GIRI_BENZINA_LR | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A | [{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0}] |
| 2A 70 00 02 9C | get_vector_indexed | 112.0 | 02 | 8 | True | 1 | 53 0C 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 97 | 8 | 0x0070 | MAP_RIF_SONDA_LAMBDA \| RIF_GIRI_BENZINA_LR | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A | [{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0},{"raw":26,"eng":26.0}] |
| 2A 71 00 00 9B | get_vector_indexed | 113.0 | 00 | 8 | True | 1 | 53 0C 29 2D 31 33 31 31 31 31 31 31 31 31 A1 | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 29 2D 31 33 31 31 31 31 31 31 31 31 | [{"raw":41,"eng":41.0},{"raw":45,"eng":45.0},{"raw":49,"eng":49.0},{"raw":51,"eng":51.0},{"raw":49,"eng":49.0},{"raw":49,"eng":49.0},{"raw":49,"eng":49.0},{"raw":49,"eng":49.0},{"raw":49,"eng":49.0},{"raw":49,"eng":49.0},{"raw":49,"eng":49.0},{"raw":49,"eng":49.0}] |
| 2A 71 00 01 9C | get_vector_indexed | 113.0 | 01 | 8 | True | 1 | 53 0C 2D 32 36 38 35 35 35 35 35 35 35 35 D4 | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 2D 32 36 38 35 35 35 35 35 35 35 35 | [{"raw":45,"eng":45.0},{"raw":50,"eng":50.0},{"raw":54,"eng":54.0},{"raw":56,"eng":56.0},{"raw":53,"eng":53.0},{"raw":53,"eng":53.0},{"raw":53,"eng":53.0},{"raw":53,"eng":53.0},{"raw":53,"eng":53.0},{"raw":53,"eng":53.0},{"raw":53,"eng":53.0},{"raw":53,"eng":53.0}] |
| 2A 71 00 02 9D | get_vector_indexed | 113.0 | 02 | 8 | True | 1 | 53 0C 32 36 3A 3C 3A 3A 3A 3A 3A 3A 3A 3A 0D | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 32 36 3A 3C 3A 3A 3A 3A 3A 3A 3A 3A | [{"raw":50,"eng":50.0},{"raw":54,"eng":54.0},{"raw":58,"eng":58.0},{"raw":60,"eng":60.0},{"raw":58,"eng":58.0},{"raw":58,"eng":58.0},{"raw":58,"eng":58.0},{"raw":58,"eng":58.0},{"raw":58,"eng":58.0},{"raw":58,"eng":58.0},{"raw":58,"eng":58.0},{"raw":58,"eng":58.0}] |
| 2A 71 00 03 9E | get_vector_indexed | 113.0 | 03 | 8 | True | 1 | 53 0C 36 3B 3F 42 3F 3F 3F 3F 3F 3F 3F 3F 49 | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 36 3B 3F 42 3F 3F 3F 3F 3F 3F 3F 3F | [{"raw":54,"eng":54.0},{"raw":59,"eng":59.0},{"raw":63,"eng":63.0},{"raw":66,"eng":66.0},{"raw":63,"eng":63.0},{"raw":63,"eng":63.0},{"raw":63,"eng":63.0},{"raw":63,"eng":63.0},{"raw":63,"eng":63.0},{"raw":63,"eng":63.0},{"raw":63,"eng":63.0},{"raw":63,"eng":63.0}] |
| 2A 71 00 04 9F | get_vector_indexed | 113.0 | 04 | 8 | True | 1 | 53 0C 39 3F 44 47 44 44 44 44 44 44 44 44 82 | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 39 3F 44 47 44 44 44 44 44 44 44 44 | [{"raw":57,"eng":57.0},{"raw":63,"eng":63.0},{"raw":68,"eng":68.0},{"raw":71,"eng":71.0},{"raw":68,"eng":68.0},{"raw":68,"eng":68.0},{"raw":68,"eng":68.0},{"raw":68,"eng":68.0},{"raw":68,"eng":68.0},{"raw":68,"eng":68.0},{"raw":68,"eng":68.0},{"raw":68,"eng":68.0}] |
| 2A 71 00 05 A0 | get_vector_indexed | 113.0 | 05 | 8 | True | 1 | 53 0C 3D 43 48 4D 4A 4A 4A 4A 4A 4A 4A 4A C4 | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 3D 43 48 4D 4A 4A 4A 4A 4A 4A 4A 4A | [{"raw":61,"eng":61.0},{"raw":67,"eng":67.0},{"raw":72,"eng":72.0},{"raw":77,"eng":77.0},{"raw":74,"eng":74.0},{"raw":74,"eng":74.0},{"raw":74,"eng":74.0},{"raw":74,"eng":74.0},{"raw":74,"eng":74.0},{"raw":74,"eng":74.0},{"raw":74,"eng":74.0},{"raw":74,"eng":74.0}] |
| 2A 71 00 06 A1 | get_vector_indexed | 113.0 | 06 | 8 | True | 1 | 53 0C 41 47 4D 53 4F 4F 4F 4F 4F 4F 4F 4F FF | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 41 47 4D 53 4F 4F 4F 4F 4F 4F 4F 4F | [{"raw":65,"eng":65.0},{"raw":71,"eng":71.0},{"raw":77,"eng":77.0},{"raw":83,"eng":83.0},{"raw":79,"eng":79.0},{"raw":79,"eng":79.0},{"raw":79,"eng":79.0},{"raw":79,"eng":79.0},{"raw":79,"eng":79.0},{"raw":79,"eng":79.0},{"raw":79,"eng":79.0},{"raw":79,"eng":79.0}] |
| 2A 71 00 07 A2 | get_vector_indexed | 113.0 | 07 | 8 | True | 1 | 53 0C 46 4D 52 5A 56 56 56 56 56 56 56 56 4E | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 46 4D 52 5A 56 56 56 56 56 56 56 56 | [{"raw":70,"eng":70.0},{"raw":77,"eng":77.0},{"raw":82,"eng":82.0},{"raw":90,"eng":90.0},{"raw":86,"eng":86.0},{"raw":86,"eng":86.0},{"raw":86,"eng":86.0},{"raw":86,"eng":86.0},{"raw":86,"eng":86.0},{"raw":86,"eng":86.0},{"raw":86,"eng":86.0},{"raw":86,"eng":86.0}] |
| 2A 71 00 08 A3 | get_vector_indexed | 113.0 | 08 | 8 | True | 1 | 53 0C 4A 52 58 61 5D 5D 5D 5D 5D 5D 5D 5D 9C | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 4A 52 58 61 5D 5D 5D 5D 5D 5D 5D 5D | [{"raw":74,"eng":74.0},{"raw":82,"eng":82.0},{"raw":88,"eng":88.0},{"raw":97,"eng":97.0},{"raw":93,"eng":93.0},{"raw":93,"eng":93.0},{"raw":93,"eng":93.0},{"raw":93,"eng":93.0},{"raw":93,"eng":93.0},{"raw":93,"eng":93.0},{"raw":93,"eng":93.0},{"raw":93,"eng":93.0}] |
| 2A 71 00 09 A4 | get_vector_indexed | 113.0 | 09 | 8 | True | 1 | 53 0C 50 57 5E 67 62 62 62 62 62 62 62 62 DB | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 50 57 5E 67 62 62 62 62 62 62 62 62 | [{"raw":80,"eng":80.0},{"raw":87,"eng":87.0},{"raw":94,"eng":94.0},{"raw":103,"eng":103.0},{"raw":98,"eng":98.0},{"raw":98,"eng":98.0},{"raw":98,"eng":98.0},{"raw":98,"eng":98.0},{"raw":98,"eng":98.0},{"raw":98,"eng":98.0},{"raw":98,"eng":98.0},{"raw":98,"eng":98.0}] |
| 2A 71 00 0A A5 | get_vector_indexed | 113.0 | 0a | 8 | True | 1 | 53 0C 55 5C 63 6B 67 67 67 67 67 67 67 67 16 | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 55 5C 63 6B 67 67 67 67 67 67 67 67 | [{"raw":85,"eng":85.0},{"raw":92,"eng":92.0},{"raw":99,"eng":99.0},{"raw":107,"eng":107.0},{"raw":103,"eng":103.0},{"raw":103,"eng":103.0},{"raw":103,"eng":103.0},{"raw":103,"eng":103.0},{"raw":103,"eng":103.0},{"raw":103,"eng":103.0},{"raw":103,"eng":103.0},{"raw":103,"eng":103.0}] |
| 2A 71 00 0B A6 | get_vector_indexed | 113.0 | 0b | 8 | True | 1 | 53 0C 5A 61 67 6E 6A 6A 6A 6A 6A 6A 6A 6A 3F | 8 | 0x0071 | ADATTA_PARAMETRI_K_LR \| MAPPA_FILTRO_BENZINA | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 5A 61 67 6E 6A 6A 6A 6A 6A 6A 6A 6A | [{"raw":90,"eng":90.0},{"raw":97,"eng":97.0},{"raw":103,"eng":103.0},{"raw":110,"eng":110.0},{"raw":106,"eng":106.0},{"raw":106,"eng":106.0},{"raw":106,"eng":106.0},{"raw":106,"eng":106.0},{"raw":106,"eng":106.0},{"raw":106,"eng":106.0},{"raw":106,"eng":106.0},{"raw":106,"eng":106.0}] |
| 2A 0D 00 00 37 | get_vector_indexed | 13.0 | 00 | 8 | True | 1 | 53 08 00 01 02 B6 B6 B6 B6 B6 EC | 8 | 0x000D | DIAGNOSI_SWITCHON_LR \| SEQUENZA_INIEZIONE | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 00 01 02 B6 B6 B6 B6 B6 | [{"raw":0,"eng":0.0},{"raw":1,"eng":1.0},{"raw":2,"eng":2.0},{"raw":182,"eng":182.0},{"raw":182,"eng":182.0},{"raw":182,"eng":182.0},{"raw":182,"eng":182.0},{"raw":182,"eng":182.0}] |
| 2A 0D 00 01 38 | get_vector_indexed | 13.0 | 01 | 8 | True | 1 | 53 08 01 02 0C 00 00 00 00 00 6A | 8 | 0x000D | DIAGNOSI_SWITCHON_LR \| SEQUENZA_INIEZIONE | TSTREAMDATI | TAebMatrix \| TAebVector | ack | 01 02 0C 00 00 00 00 00 | [{"raw":1,"eng":1.0},{"raw":2,"eng":2.0},{"raw":12,"eng":12.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 8F 00 00 B9 | get_vector_indexed | 143.0 | 00 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 8F 00 01 BA | get_vector_indexed | 143.0 | 01 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 8F 00 02 BB | get_vector_indexed | 143.0 | 02 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 8F 00 03 BC | get_vector_indexed | 143.0 | 03 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 8F 00 04 BD | get_vector_indexed | 143.0 | 04 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 8F 00 05 BE | get_vector_indexed | 143.0 | 05 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 8F 00 06 BF | get_vector_indexed | 143.0 | 06 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 8F 00 07 C0 | get_vector_indexed | 143.0 | 07 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 95 00 00 BF | get_vector_indexed | 149.0 | 00 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x0095 | MAPPA_CORR_TARATURA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 95 00 01 C0 | get_vector_indexed | 149.0 | 01 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x0095 | MAPPA_CORR_TARATURA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 95 00 02 C1 | get_vector_indexed | 149.0 | 02 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x0095 | MAPPA_CORR_TARATURA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 95 00 03 C2 | get_vector_indexed | 149.0 | 03 | 8 | True | 1 | 53 04 00 00 00 00 57 | 8 | 0x0095 | MAPPA_CORR_TARATURA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 00 FA | get_vector_indexed | 208.0 | 00 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 01 FB | get_vector_indexed | 208.0 | 01 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 02 FC | get_vector_indexed | 208.0 | 02 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 03 FD | get_vector_indexed | 208.0 | 03 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 04 FE | get_vector_indexed | 208.0 | 04 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 05 FF | get_vector_indexed | 208.0 | 05 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 06 00 | get_vector_indexed | 208.0 | 06 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 07 01 | get_vector_indexed | 208.0 | 07 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 08 02 | get_vector_indexed | 208.0 | 08 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 09 03 | get_vector_indexed | 208.0 | 09 | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 0A 04 | get_vector_indexed | 208.0 | 0a | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D0 00 0B 05 | get_vector_indexed | 208.0 | 0b | 8 | True | 1 | 53 0C 00 00 00 00 00 00 00 00 00 00 00 00 5F | 8 | 0x00D0 | MAPPA_CONTRIBUTI_BENZINA | TSTREAMDATI | TAebMatrix | ack | 00 00 00 00 00 00 00 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A D7 00 00 01 | get_vector_indexed | 215.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x00D7 | MAPPA_RIF_TRANSITORI_BENZINA | TSTREAMDATI | TAebMatrix | ca_status | 01 10 | [{"raw":4097,"eng":4097.0}] |
| 2A EB 00 00 15 | get_vector_indexed | 235.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x00EB | MAPPA_ADATTA | TSTREAMDATI | TAebMatrix | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 2A F0 00 00 1A | get_vector_indexed | 240.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x00F0 | MAP_FLEX | TSTREAMDATI | TAebMatrix | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 2A 34 01 00 5F | get_vector_indexed | 308.0 | 00 | 8 | True | 1 | 53 06 00 00 04 00 F4 01 52 | 8 | 0x0134 | PARAM_PROGRESSIONI | TSTREAMDATI | TAebMatrix | ack | 00 00 04 00 F4 01 | [{"raw":0,"eng":0.0},{"raw":4,"eng":4.0},{"raw":500,"eng":500.0}] |
| 2A 34 01 01 60 | get_vector_indexed | 308.0 | 01 | 8 | True | 1 | 53 06 14 00 04 00 F4 01 66 | 8 | 0x0134 | PARAM_PROGRESSIONI | TSTREAMDATI | TAebMatrix | ack | 14 00 04 00 F4 01 | [{"raw":20,"eng":20.0},{"raw":4,"eng":4.0},{"raw":500,"eng":500.0}] |
| 2A 34 01 02 61 | get_vector_indexed | 308.0 | 02 | 8 | True | 1 | 53 06 14 00 04 00 F4 01 66 | 8 | 0x0134 | PARAM_PROGRESSIONI | TSTREAMDATI | TAebMatrix | ack | 14 00 04 00 F4 01 | [{"raw":20,"eng":20.0},{"raw":4,"eng":4.0},{"raw":500,"eng":500.0}] |
| 2A 34 01 03 62 | get_vector_indexed | 308.0 | 03 | 8 | True | 1 | 53 06 19 00 04 00 F4 01 6B | 8 | 0x0134 | PARAM_PROGRESSIONI | TSTREAMDATI | TAebMatrix | ack | 19 00 04 00 F4 01 | [{"raw":25,"eng":25.0},{"raw":4,"eng":4.0},{"raw":500,"eng":500.0}] |
| 2A 1F 00 00 49 | get_vector_indexed | 31.0 | 00 | 8 | True | 1 | 53 05 7B 00 00 00 00 D3 | 8 | 0x001F | ACTION_DIAGNOSI \| TEMPO_CICCHETTO_LR | TSTREAMDATI | TAebMatrix \| TAebNumber | ack | 7B 00 00 00 00 | [{"raw":123,"eng":123.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 1F 00 01 4A | get_vector_indexed | 31.0 | 01 | 8 | True | 1 | 53 05 00 00 00 00 00 58 | 8 | 0x001F | ACTION_DIAGNOSI \| TEMPO_CICCHETTO_LR | TSTREAMDATI | TAebMatrix \| TAebNumber | ack | 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 1F 00 02 4B | get_vector_indexed | 31.0 | 02 | 8 | True | 1 | 53 05 00 00 00 00 00 58 | 8 | 0x001F | ACTION_DIAGNOSI \| TEMPO_CICCHETTO_LR | TSTREAMDATI | TAebMatrix \| TAebNumber | ack | 00 00 00 00 00 | [{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0},{"raw":0,"eng":0.0}] |
| 2A 3E 01 00 69 | get_vector_indexed | 318.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x013E | INJR_TOFS_TBL | TSTREAMDATI | TAebMatrix | ca_status | 01 10 | [{"raw":4097,"eng":1.00024414}] |
| 2A 2C 00 00 56 | get_vector_indexed | 44.0 | 00 | 8 | True | 1 | CA 01 10 DB | 8 | 0x002C | MAPPA_ANTICIPO | TSTREAMDATI | TAebMatrix | ca_status | 01 10 | [{"raw":1,"eng":1.0},{"raw":16,"eng":16.0}] |
| 2A 2E 00 00 58 | get_vector_indexed | 46.0 | 00 | 8 | True | 1 | 53 09 FF F0 96 69 4B 3C 2D 1E 0F 2B | 8 | 0x002E | MAPPA_DELAY_GAS_TEMP | TSTREAMDATI | TAebMatrix | ack | FF F0 96 69 4B 3C 2D 1E 0F | [{"raw":255,"eng":255.0},{"raw":240,"eng":240.0},{"raw":150,"eng":150.0},{"raw":105,"eng":105.0},{"raw":75,"eng":75.0},{"raw":60,"eng":60.0},{"raw":45,"eng":45.0},{"raw":30,"eng":30.0},{"raw":15,"eng":15.0}] |
| 2A 2E 00 01 59 | get_vector_indexed | 46.0 | 01 | 8 | True | 1 | 53 09 E1 E1 B4 96 78 5A 3C 3C 2D DF | 8 | 0x002E | MAPPA_DELAY_GAS_TEMP | TSTREAMDATI | TAebMatrix | ack | E1 E1 B4 96 78 5A 3C 3C 2D | [{"raw":225,"eng":225.0},{"raw":225,"eng":225.0},{"raw":180,"eng":180.0},{"raw":150,"eng":150.0},{"raw":120,"eng":120.0},{"raw":90,"eng":90.0},{"raw":60,"eng":60.0},{"raw":60,"eng":60.0},{"raw":45,"eng":45.0}] |
| 2A 54 00 00 7E | get_vector_indexed | 84.0 | 00 | 8 | True | 3 | 53 0C B6 B5 B1 B5 B3 B5 B3 B3 AC AB 93 AB 93 | 6 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B6 B5 B1 B5 B3 B5 B3 B3 AC AB 93 AB | [{"raw":182,"eng":182.0},{"raw":181,"eng":181.0},{"raw":177,"eng":177.0},{"raw":181,"eng":181.0},{"raw":179,"eng":179.0},{"raw":181,"eng":181.0},{"raw":179,"eng":179.0},{"raw":179,"eng":179.0},{"raw":172,"eng":172.0},{"raw":171,"eng":171.0},{"raw":147,"eng":147.0},{"raw":171,"eng":171.0}] |
| 2A 54 00 01 7F | get_vector_indexed | 84.0 | 01 | 8 | True | 1 | 53 0C B6 B5 B3 B5 B3 B5 B5 B8 B6 AD AE AE C6 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B6 B5 B3 B5 B3 B5 B5 B8 B6 AD AE AE | [{"raw":182,"eng":182.0},{"raw":181,"eng":181.0},{"raw":179,"eng":179.0},{"raw":181,"eng":181.0},{"raw":179,"eng":179.0},{"raw":181,"eng":181.0},{"raw":181,"eng":181.0},{"raw":184,"eng":184.0},{"raw":182,"eng":182.0},{"raw":173,"eng":173.0},{"raw":174,"eng":174.0},{"raw":174,"eng":174.0}] |
| 2A 54 00 02 80 | get_vector_indexed | 84.0 | 02 | 8 | True | 1 | 53 0C B8 B7 B5 B7 B8 B4 B3 AB AD AC AC AC B5 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B8 B7 B5 B7 B8 B4 B3 AB AD AC AC AC | [{"raw":184,"eng":184.0},{"raw":183,"eng":183.0},{"raw":181,"eng":181.0},{"raw":183,"eng":183.0},{"raw":184,"eng":184.0},{"raw":180,"eng":180.0},{"raw":179,"eng":179.0},{"raw":171,"eng":171.0},{"raw":173,"eng":173.0},{"raw":172,"eng":172.0},{"raw":172,"eng":172.0},{"raw":172,"eng":172.0}] |
| 2A 54 00 03 81 | get_vector_indexed | 84.0 | 03 | 8 | True | 1 | 53 0C B6 B6 B6 B8 B8 B3 B5 A8 AE AF AB AB B4 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B6 B6 B6 B8 B8 B3 B5 A8 AE AF AB AB | [{"raw":182,"eng":182.0},{"raw":182,"eng":182.0},{"raw":182,"eng":182.0},{"raw":184,"eng":184.0},{"raw":184,"eng":184.0},{"raw":179,"eng":179.0},{"raw":181,"eng":181.0},{"raw":168,"eng":168.0},{"raw":174,"eng":174.0},{"raw":175,"eng":175.0},{"raw":171,"eng":171.0},{"raw":171,"eng":171.0}] |
| 2A 54 00 04 82 | get_vector_indexed | 84.0 | 04 | 8 | True | 1 | 53 0C BC B4 B4 BC B8 B5 B3 B4 AD AA AD AE C5 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | BC B4 B4 BC B8 B5 B3 B4 AD AA AD AE | [{"raw":188,"eng":188.0},{"raw":180,"eng":180.0},{"raw":180,"eng":180.0},{"raw":188,"eng":188.0},{"raw":184,"eng":184.0},{"raw":181,"eng":181.0},{"raw":179,"eng":179.0},{"raw":180,"eng":180.0},{"raw":173,"eng":173.0},{"raw":170,"eng":170.0},{"raw":173,"eng":173.0},{"raw":174,"eng":174.0}] |
| 2A 54 00 05 83 | get_vector_indexed | 84.0 | 05 | 8 | True | 1 | 53 0C BC B9 BA BA B8 B7 B4 AD AD AF AB AC CB | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | BC B9 BA BA B8 B7 B4 AD AD AF AB AC | [{"raw":188,"eng":188.0},{"raw":185,"eng":185.0},{"raw":186,"eng":186.0},{"raw":186,"eng":186.0},{"raw":184,"eng":184.0},{"raw":183,"eng":183.0},{"raw":180,"eng":180.0},{"raw":173,"eng":173.0},{"raw":173,"eng":173.0},{"raw":175,"eng":175.0},{"raw":171,"eng":171.0},{"raw":172,"eng":172.0}] |
| 2A 54 00 06 84 | get_vector_indexed | 84.0 | 06 | 8 | True | 1 | 53 0C B7 B8 B4 B8 B8 B8 B1 B0 B1 B0 AE AE C8 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B7 B8 B4 B8 B8 B8 B1 B0 B1 B0 AE AE | [{"raw":183,"eng":183.0},{"raw":184,"eng":184.0},{"raw":180,"eng":180.0},{"raw":184,"eng":184.0},{"raw":184,"eng":184.0},{"raw":184,"eng":184.0},{"raw":177,"eng":177.0},{"raw":176,"eng":176.0},{"raw":177,"eng":177.0},{"raw":176,"eng":176.0},{"raw":174,"eng":174.0},{"raw":174,"eng":174.0}] |
| 2A 54 00 07 85 | get_vector_indexed | 84.0 | 07 | 8 | True | 2 | 53 0C B7 B7 B5 B9 B6 B7 B8 BE BF C0 AC AC F5 | 7 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B7 B7 B5 B9 B6 B7 B8 BE BF C0 AC AC | [{"raw":183,"eng":183.0},{"raw":183,"eng":183.0},{"raw":181,"eng":181.0},{"raw":185,"eng":185.0},{"raw":182,"eng":182.0},{"raw":183,"eng":183.0},{"raw":184,"eng":184.0},{"raw":190,"eng":190.0},{"raw":191,"eng":191.0},{"raw":192,"eng":192.0},{"raw":172,"eng":172.0},{"raw":172,"eng":172.0}] |
| 2A 54 00 08 86 | get_vector_indexed | 84.0 | 08 | 8 | True | 1 | 53 0C B7 B6 B4 B5 B6 BA B4 BD BC BC AF AF EC | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B7 B6 B4 B5 B6 BA B4 BD BC BC AF AF | [{"raw":183,"eng":183.0},{"raw":182,"eng":182.0},{"raw":180,"eng":180.0},{"raw":181,"eng":181.0},{"raw":182,"eng":182.0},{"raw":186,"eng":186.0},{"raw":180,"eng":180.0},{"raw":189,"eng":189.0},{"raw":188,"eng":188.0},{"raw":188,"eng":188.0},{"raw":175,"eng":175.0},{"raw":175,"eng":175.0}] |
| 2A 54 00 09 87 | get_vector_indexed | 84.0 | 09 | 8 | True | 1 | 53 0C B7 B7 BA BF B9 B7 B7 BF BE BA B1 B1 06 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B7 B7 BA BF B9 B7 B7 BF BE BA B1 B1 | [{"raw":183,"eng":183.0},{"raw":183,"eng":183.0},{"raw":186,"eng":186.0},{"raw":191,"eng":191.0},{"raw":185,"eng":185.0},{"raw":183,"eng":183.0},{"raw":183,"eng":183.0},{"raw":191,"eng":191.0},{"raw":190,"eng":190.0},{"raw":186,"eng":186.0},{"raw":177,"eng":177.0},{"raw":177,"eng":177.0}] |
| 2A 54 00 0A 88 | get_vector_indexed | 84.0 | 0a | 8 | True | 1 | 53 0C B2 B5 BA BC B7 B6 B8 BA BD BD AE AE F1 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B2 B5 BA BC B7 B6 B8 BA BD BD AE AE | [{"raw":178,"eng":178.0},{"raw":181,"eng":181.0},{"raw":186,"eng":186.0},{"raw":188,"eng":188.0},{"raw":183,"eng":183.0},{"raw":182,"eng":182.0},{"raw":184,"eng":184.0},{"raw":186,"eng":186.0},{"raw":189,"eng":189.0},{"raw":189,"eng":189.0},{"raw":174,"eng":174.0},{"raw":174,"eng":174.0}] |
| 2A 54 00 0B 89 | get_vector_indexed | 84.0 | 0b | 8 | True | 1 | 53 0C B5 B6 B6 BF BE B3 B9 C0 C0 BA AB AB F9 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | B5 B6 B6 BF BE B3 B9 C0 C0 BA AB AB | [{"raw":181,"eng":181.0},{"raw":182,"eng":182.0},{"raw":182,"eng":182.0},{"raw":191,"eng":191.0},{"raw":190,"eng":190.0},{"raw":179,"eng":179.0},{"raw":185,"eng":185.0},{"raw":192,"eng":192.0},{"raw":192,"eng":192.0},{"raw":186,"eng":186.0},{"raw":171,"eng":171.0},{"raw":171,"eng":171.0}] |
| 2A 54 00 0C 8A | get_vector_indexed | 84.0 | 0c | 8 | True | 1 | 53 0C 6E 6E 6E 6E 6E 6E 70 71 72 73 74 74 A1 | 8 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack | 6E 6E 6E 6E 6E 6E 70 71 72 73 74 74 | [{"raw":110,"eng":110.0},{"raw":110,"eng":110.0},{"raw":110,"eng":110.0},{"raw":110,"eng":110.0},{"raw":110,"eng":110.0},{"raw":110,"eng":110.0},{"raw":112,"eng":112.0},{"raw":113,"eng":113.0},{"raw":114,"eng":114.0},{"raw":115,"eng":115.0},{"raw":116,"eng":116.0},{"raw":116,"eng":116.0}] |
| 00 02 02 | init_stage_1 |  |  | 32 | True | 2 | 53 04 FE 4F 45 0B F4 | 24 |  |  |  |  | ack | FE 4F 45 0B |  |
| 01 00 3A 3B | init_stage_2 |  |  | 19 | True | 1 | 53 00 53 | 19 |  |  |  |  | ack |  |  |
| 12 0A 00 1F 3B | set_number | 10.0 | 1f | 2 | True | 1 | 53 00 53 | 2 | 0x000A | RIF_SUP_LAMBDA_CALDA | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 64 00 28 23 C2 | set_number | 100.0 | 2823 | 2 | True | 1 | 53 00 53 | 2 | 0x0064 | GIRI_SUP_BENZINA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 6A 00 00 7C | set_number | 106.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x006A | NUMERO_INJ_BENZINA_CUTOFF \| SOGLIA_FLUSSO_SUBSONICO_LR | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 6B 00 00 7D | set_number | 107.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x006B | RITARDO_GIRI_EMULAZIONE_HIGH \| TAGLIA_INIETTORI_LR | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 6D 00 00 7F | set_number | 109.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x006D | TEMPO_SOVRAPPOSIZIONE | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 0B 00 0F 2C | set_number | 11.0 | 0f | 2 | True | 1 | 53 00 53 | 2 | 0x000B | RIF_INF_LAMBDA_CALDA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 6E 00 4B CB | set_number | 110.0 | 4b | 2 | True | 1 | 53 00 53 | 2 | 0x006E | TEMPERATURA_GAS_AVVIO_LR \| TEMPO_CICCHETTO | TSTREAMDATI | TAebNumber \| TAebVector | ack |  |  |
| 12 74 00 32 B8 | set_number | 116.0 | 32 | 2 | True | 1 | 53 00 53 | 2 | 0x0074 | CORR_ARRICCHIMENTO \| TIPO_CONNESSIONE_OBD_LR | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 75 00 B6 3D | set_number | 117.0 | b6 | 2 | True | 1 | 53 00 53 | 2 | 0x0075 | TEMP_GAS_CAMBIO \| TEMP_RID_CAMBIO_LR | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 76 00 14 9C | set_number | 118.0 | 14 | 2 | True | 1 | 53 00 53 | 2 | 0x0076 | IMPEDENZA_INIETTORI | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 77 00 2D B6 | set_number | 119.0 | 2d | 2 | True | 1 | 53 00 53 | 2 | 0x0077 | VAL_PERC_HOLDING_CURRENT | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 7D 00 EA 00 7A | set_number | 125.0 | ea00 | 2 | True | 1 | 53 00 53 | 2 | 0x007D | TEMPO_MORTO_INIETTORI_BENZINA | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 7E 00 87 01 19 | set_number | 126.0 | 8701 | 2 | True | 1 | 53 00 53 | 2 | 0x007E | TEMPO_MORTO_INIETTORI_GAS | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 86 00 00 98 | set_number | 134.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x0086 | TIPO_SENSORE_TEMPERATURA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 87 00 00 99 | set_number | 135.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x0087 | RITARDO_GIRI_EMULAZIONE | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 88 00 64 FE | set_number | 136.0 | 64 | 2 | True | 1 | 53 00 53 | 2 | 0x0088 | SMAGRIMENTO_RIENTRO_CUTOFF | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 89 00 00 9B | set_number | 137.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x0089 | NUMERO_INIETTATE_SMAGRIMENTO | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 90 00 43 E5 | set_number | 144.0 | 43 | 2 | True | 1 | 53 00 53 | 2 | 0x0090 | TEMP_AUTOTARATURA | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 92 00 4F 12 06 | set_number | 146.0 | 4f12 | 2 | True | 1 | 53 00 53 | 2 | 0x0092 | T_INJ_BENZ_MAX_CAMBIO | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 93 00 75 00 1B | set_number | 147.0 | 7500 | 2 | True | 1 | 53 00 53 | 2 | 0x0093 | SPOSTAMENTO_TARATURA | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 94 00 01 25 CD | set_number | 148.0 | 0125 | 2 | True | 1 | 53 00 53 | 2 | 0x0094 | TIPO_INIETTORE | TSTREAMDATI | TAebVector | ack |  |  |
| 12 0F 00 58 79 | set_number | 15.0 | 58 | 2 | True | 1 | 53 00 53 | 2 | 0x000F | TEMP_GAS_CAMBIO_LR \| TEMP_RID_CAMBIO | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 96 00 58 02 03 | set_number | 150.0 | 5802 | 2 | True | 1 | 53 00 53 | 2 | 0x0096 | GIRI_AUTOTARATURA | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 9C 00 23 02 D4 | set_number | 156.0 | 2302 | 2 | True | 1 | 53 00 53 | 2 | 0x009C | TEMPO_MAX_EXTRAINJ_BENZ | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 10 00 B0 04 D7 | set_number | 16.0 | b004 | 2 | True | 1 | 53 00 53 | 2 | 0x0010 | GIRI_MIN_CAMBIO | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 11 00 23 46 | set_number | 17.0 | 23 | 2 | True | 1 | 53 00 53 | 2 | 0x0011 | RITARDO_CAMBIO | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 AB 00 00 BD | set_number | 171.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x00AB | RIF_TEMP_GAS_OFFSET_LR \| TIPI_SONDA_LAMBDA | TSTREAMDATI | TAebNumber \| TAebVector | ack |  |  |
| 13 AC 00 00 00 BF | set_number | 172.0 | 0000 | 2 | True | 1 | 53 00 53 | 2 | 0x00AC | MASK_INIETTORI_BENZINA \| TEMPO_MORTO_INIETTORI_LR | TSTREAMDATI | TAebNumber \| TAebVector | ack |  |  |
| 12 B0 00 00 C2 | set_number | 176.0 | 00 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00B0 | GIRI_PER_BENZINA_LR \| LAMBDA_OFFSET | TSTREAMDATI | TAebNumber \| TAebVector | ca_status | 01 10 |  |
| 12 B2 00 00 C4 | set_number | 178.0 | 00 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00B2 | MASK_INIETTORI_BENZINA_LR \| RITARDO_CAMBIO_HIGH | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 12 00 00 00 25 | set_number | 18.0 | 0000 | 2 | True | 1 | 53 00 53 | 2 | 0x0012 | TEST_WORD | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 B4 00 00 C6 | set_number | 180.0 | 00 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00B4 | SMAGRIMENTO_MIN | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 12 B5 00 00 C7 | set_number | 181.0 | 00 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00B5 | TIPO_CARBURANTE | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 B6 00 00 00 C9 | set_number | 182.0 | 0000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00B6 | SMP_CALIBRATO | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 12 BB 00 00 CD | set_number | 187.0 | 00 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00BB | CORRETTORE_BANCATA2_LR \| TIPO_CONNESSIONE_OBD | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 12 BC 00 55 23 | set_number | 188.0 | 55 | 2 | True | 1 | 53 00 53 | 2 | 0x00BC | K_MAPPA_NEUTRO | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 BF 00 00 D1 | set_number | 191.0 | 00 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00BF | SPLIT_FUEL | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 12 C3 00 32 07 | set_number | 195.0 | 32 | 2 | True | 1 | 53 00 53 | 2 | 0x00C3 | TEMP_GAS_CALDO | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 14 00 41 67 | set_number | 20.0 | 41 | 2 | True | 1 | 53 00 53 | 2 | 0x0014 | TIPO_ACCENS | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 C8 00 F4 01 D0 | set_number | 200.0 | f401 | 2 | True | 1 | 53 00 53 | 2 | 0x00C8 | RPM_FOR_SPLIT_FUEL | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 C9 00 C4 09 A9 | set_number | 201.0 | c409 | 2 | True | 1 | 53 00 53 | 2 | 0x00C9 | OVER_PRESSURE_DIAGNOSYS | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 CF 00 00 00 E2 | set_number | 207.0 | 0000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00CF | RITARDO_ATTIVAZIONE_INIETTORI | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 12 D5 00 09 F0 | set_number | 213.0 | 09 | 2 | True | 1 | 53 00 53 | 2 | 0x00D5 | NUMERO_PARTENZE_EMERGENZA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 16 00 05 2D | set_number | 22.0 | 05 | 2 | True | 1 | 53 00 53 | 2 | 0x0016 | SMAGRIMENTO_EXTRA \| TAGLIA_INIETTORE_LR | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 DE 00 36 26 | set_number | 222.0 | 36 | 2 | True | 1 | 53 00 53 | 2 | 0x00DE | SOGLIA_FLUSSO_SUBSONICO | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 E1 00 00 F3 | set_number | 225.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x00E1 | TAGLIA_INIETTORE | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 E6 00 03 FB | set_number | 230.0 | 03 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00E6 | SOGLIA_CORRETTORE_GAS | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 EF 00 14 05 1B | set_number | 239.0 | 1405 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00EF | SOGLIA_GIRI_ADATTATIVITA_WORD | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 12 F9 00 00 0B | set_number | 249.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x00F9 | NUM_DENTI_ALBERO_CAMME | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 1B 00 00 00 2E | set_number | 27.0 | 0000 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 01 00 2F | set_number | 27.0 | 0100 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 02 00 30 | set_number | 27.0 | 0200 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 03 00 31 | set_number | 27.0 | 0300 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 04 00 32 | set_number | 27.0 | 0400 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 05 00 33 | set_number | 27.0 | 0500 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 06 00 34 | set_number | 27.0 | 0600 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 07 00 35 | set_number | 27.0 | 0700 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 08 00 36 | set_number | 27.0 | 0800 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 09 00 37 | set_number | 27.0 | 0900 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 0A 00 38 | set_number | 27.0 | 0a00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 0B 00 39 | set_number | 27.0 | 0b00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 0C 00 3A | set_number | 27.0 | 0c00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 0D 00 3B | set_number | 27.0 | 0d00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 0E 00 3C | set_number | 27.0 | 0e00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 0F 00 3D | set_number | 27.0 | 0f00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 10 00 3E | set_number | 27.0 | 1000 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 11 00 3F | set_number | 27.0 | 1100 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 12 00 40 | set_number | 27.0 | 1200 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 13 00 41 | set_number | 27.0 | 1300 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 14 00 42 | set_number | 27.0 | 1400 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 15 00 43 | set_number | 27.0 | 1500 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 16 00 44 | set_number | 27.0 | 1600 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 17 00 45 | set_number | 27.0 | 1700 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 18 00 46 | set_number | 27.0 | 1800 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 19 00 47 | set_number | 27.0 | 1900 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 1A 00 48 | set_number | 27.0 | 1a00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 1B 00 49 | set_number | 27.0 | 1b00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 1C 00 4A | set_number | 27.0 | 1c00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 1D 00 4B | set_number | 27.0 | 1d00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 1E 00 4C | set_number | 27.0 | 1e00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 1F 00 4D | set_number | 27.0 | 1f00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 20 00 4E | set_number | 27.0 | 2000 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 21 00 4F | set_number | 27.0 | 2100 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 22 00 50 | set_number | 27.0 | 2200 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 23 00 51 | set_number | 27.0 | 2300 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 24 00 52 | set_number | 27.0 | 2400 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 25 00 53 | set_number | 27.0 | 2500 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 26 00 54 | set_number | 27.0 | 2600 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 27 00 55 | set_number | 27.0 | 2700 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 28 00 56 | set_number | 27.0 | 2800 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 29 00 57 | set_number | 27.0 | 2900 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 2A 00 58 | set_number | 27.0 | 2a00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 2B 00 59 | set_number | 27.0 | 2b00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 2C 00 5A | set_number | 27.0 | 2c00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 2D 00 5B | set_number | 27.0 | 2d00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 2E 00 5C | set_number | 27.0 | 2e00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 13 1B 00 2F 00 5D | set_number | 27.0 | 2f00 | 2 | True | 1 | 53 00 53 | 2 | 0x001B | NOTE_CONFIG | TSTREAMDATI | TAebVector | ack |  |  |
| 14 14 01 00 00 80 A9 | set_number | 276.0 | 000080 | 2 | True | 1 | 53 00 53 | 2 | 0x0114 | LO_PASS_FILT_CON_FAST \| LO_PASS_FILT_CON_SLOW | TSTREAMDATI | TAebNumber | ack |  |  |
| 14 14 01 01 33 13 70 | set_number | 276.0 | 013313 | 2 | True | 1 | 53 00 53 | 2 | 0x0114 | LO_PASS_FILT_CON_FAST \| LO_PASS_FILT_CON_SLOW | TSTREAMDATI | TAebNumber | ack |  |  |
| 14 23 01 01 00 14 4D | set_number | 291.0 | 010014 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0123 | PRESS_INSUL_DIAG_MIN_TANK_LVL_THD | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 24 01 01 9A 00 D4 | set_number | 292.0 | 019a00 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0124 | LO_PRESS_INSUL_DIAG_FALL_THD | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 25 01 02 00 14 50 | set_number | 293.0 | 020014 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0125 | PRESS_INSUL_DIAG_AFT_CRK_DLY \| PRESS_INSUL_DIAG_PRESS_ZNT \| PRESS_INSUL_DIAG_PRESS_ZNT_OUT | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 25 01 03 00 04 41 | set_number | 293.0 | 030004 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0125 | PRESS_INSUL_DIAG_AFT_CRK_DLY \| PRESS_INSUL_DIAG_PRESS_ZNT \| PRESS_INSUL_DIAG_PRESS_ZNT_OUT | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 25 01 04 00 14 52 | set_number | 293.0 | 040014 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0125 | PRESS_INSUL_DIAG_AFT_CRK_DLY \| PRESS_INSUL_DIAG_PRESS_ZNT \| PRESS_INSUL_DIAG_PRESS_ZNT_OUT | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 27 01 00 14 4F | set_number | 295.0 | 0014 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0127 | PRESS_INSUL_DIAG_WAT_TEMP_HI_THD \| PRESS_INSUL_DIAG_WAT_TEMP_LO_THD | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 27 01 01 80 BC | set_number | 295.0 | 0180 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0127 | PRESS_INSUL_DIAG_WAT_TEMP_HI_THD \| PRESS_INSUL_DIAG_WAT_TEMP_LO_THD | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 2B 01 00 04 00 44 | set_number | 299.0 | 000400 | 2 | True | 1 | CA 01 10 DB | 2 | 0x012B | PARAM_PROGRESS_0 \| PARAM_PROGRESS_1 \| PARAM_PROGRESS_2 \| PARAM_PROGRESS_3 | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 2B 01 01 F4 01 36 | set_number | 299.0 | 01f401 | 2 | True | 1 | CA 01 10 DB | 2 | 0x012B | PARAM_PROGRESS_0 \| PARAM_PROGRESS_1 \| PARAM_PROGRESS_2 \| PARAM_PROGRESS_3 | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 2B 01 02 64 00 A6 | set_number | 299.0 | 026400 | 2 | True | 1 | CA 01 10 DB | 2 | 0x012B | PARAM_PROGRESS_0 \| PARAM_PROGRESS_1 \| PARAM_PROGRESS_2 \| PARAM_PROGRESS_3 | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 2B 01 03 64 00 A7 | set_number | 299.0 | 036400 | 2 | True | 1 | CA 01 10 DB | 2 | 0x012B | PARAM_PROGRESS_0 \| PARAM_PROGRESS_1 \| PARAM_PROGRESS_2 \| PARAM_PROGRESS_3 | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 2C 01 00 03 43 | set_number | 300.0 | 0003 | 2 | True | 1 | 53 00 53 | 2 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 2C 01 01 0A 4B | set_number | 300.0 | 010a | 2 | True | 1 | 53 00 53 | 2 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 2C 01 02 25 67 | set_number | 300.0 | 0225 | 2 | True | 1 | 53 00 53 | 2 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 2C 01 03 3E 81 | set_number | 300.0 | 033e | 2 | True | 1 | 53 00 53 | 2 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 2C 01 04 5A 9E | set_number | 300.0 | 045a | 2 | True | 1 | 53 00 53 | 2 | 0x012C | ISTERESI_RIACCENSIONE \| SOGLIA_LED_1 \| SOGLIA_LED_2 \| SOGLIA_LED_3 \| SOGLIA_LED_4 | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 2F 01 00 05 48 | set_number | 303.0 | 0005 | 2 | True | 1 | 53 00 53 | 2 | 0x012F | ANTICIPO_INTERRUZIONE_WARMUP \| DELTA_AD_PER_WARMUP \| DELTA_T_RAIL_BLOCCO_DHLP | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 2F 01 01 0A 4E | set_number | 303.0 | 010a | 2 | True | 1 | 53 00 53 | 2 | 0x012F | ANTICIPO_INTERRUZIONE_WARMUP \| DELTA_AD_PER_WARMUP \| DELTA_T_RAIL_BLOCCO_DHLP | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 2F 01 02 03 48 | set_number | 303.0 | 0203 | 2 | True | 1 | 53 00 53 | 2 | 0x012F | ANTICIPO_INTERRUZIONE_WARMUP \| DELTA_AD_PER_WARMUP \| DELTA_T_RAIL_BLOCCO_DHLP | TSTREAMDATI | TAebNumber | ack |  |  |
| 14 39 01 00 1F 05 72 | set_number | 313.0 | 001f05 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0139 | INJR_GAS_FLOW \| TANK_VOL | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 39 01 01 A4 1C 0F | set_number | 313.0 | 01a41c | 2 | True | 1 | CA 01 10 DB | 2 | 0x0139 | INJR_GAS_FLOW \| TANK_VOL | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 14 3A 01 00 25 01 75 | set_number | 314.0 | 002501 | 2 | True | 1 | CA 01 10 DB | 2 | 0x013A | NORM_TEMP | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 3B 01 00 0C 5B | set_number | 315.0 | 000c | 2 | True | 1 | CA 01 10 DB | 2 | 0x013B | NORM_PRESS | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 3F 01 00 05 58 | set_number | 319.0 | 0005 | 2 | True | 1 | CA 01 10 DB | 2 | 0x013F | GEAR_MAX_NO \| GEAR_RAT_ADPY_EN | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 3F 01 02 00 55 | set_number | 319.0 | 0200 | 2 | True | 1 | CA 01 10 DB | 2 | 0x013F | GEAR_MAX_NO \| GEAR_RAT_ADPY_EN | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 13 40 01 00 04 58 | set_number | 320.0 | 0004 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0140 | MGSS_MAX_MNFLD_PRESS | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 12 4A 01 00 5D | set_number | 330.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x014A | AUTO_CAL_ENABLE | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 65 01 00 03 7C | set_number | 357.0 | 0003 | 2 | True | 1 | 53 00 53 | 2 | 0x0165 | VECT_AUTOCAL_U8_0 \| VECT_AUTOCAL_U8_1 \| VECT_AUTOCAL_U8_2 | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 65 01 01 03 7D | set_number | 357.0 | 0103 | 2 | True | 1 | 53 00 53 | 2 | 0x0165 | VECT_AUTOCAL_U8_0 \| VECT_AUTOCAL_U8_1 \| VECT_AUTOCAL_U8_2 | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 65 01 02 03 7E | set_number | 357.0 | 0203 | 2 | True | 1 | 53 00 53 | 2 | 0x0165 | VECT_AUTOCAL_U8_0 \| VECT_AUTOCAL_U8_1 \| VECT_AUTOCAL_U8_2 | TAUTOCALDM | TAebNumber | ack |  |  |
| 14 67 01 01 00 04 81 | set_number | 359.0 | 010004 | 2 | True | 1 | 53 00 53 | 2 | 0x0167 | EN_CDN_T_THD | TAUTOCALDM | TAebNumber | ack |  |  |
| 12 24 00 81 B7 | set_number | 36.0 | 81 | 2 | True | 1 | 53 00 53 | 2 | 0x0024 | TIPO_SENSORE | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 69 01 AA 00 27 | set_number | 361.0 | aa00 | 2 | True | 1 | 53 00 53 | 2 | 0x0169 | LIMIT_PRESSURE_MIN | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 6A 01 C5 01 44 | set_number | 362.0 | c501 | 2 | True | 1 | 53 00 53 | 2 | 0x016A | LIMIT_PRESSURE_MAX | TAUTOCALDM | TAebNumber | ack |  |  |
| 12 74 01 03 8A | set_number | 372.0 | 03 | 2 | True | 1 | 53 00 53 | 2 | 0x0174 | NUM_ATUOMATCH_EXECUTED | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 7A 01 B8 0B 51 | set_number | 378.0 | b80b | 2 | True | 1 | 53 00 53 | 2 | 0x017A | MAX_RPM_FOR_AUTOCAL | TAUTOCALDM | TAebNumber | ack |  |  |
| 12 7B 01 00 8E | set_number | 379.0 | 00 | 6 | True | 1 | 53 00 53 | 6 | 0x017B | SP_EN_STRATEGIA_EMU_SENS_PRESS_CLIMA \| SP_EN_STRATEGIA_MINIMO \| SP_EN_STRATEGIA_RIC_CLIMA | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 00 F4 01 86 | set_number | 380.0 | 00f401 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 01 D0 07 69 | set_number | 380.0 | 01d007 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 02 64 00 F7 | set_number | 380.0 | 026400 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 03 F4 01 89 | set_number | 380.0 | 03f401 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 04 D0 07 6C | set_number | 380.0 | 04d007 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 05 64 00 FA | set_number | 380.0 | 056400 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 06 01 00 98 | set_number | 380.0 | 060100 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 07 00 00 98 | set_number | 380.0 | 070000 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 08 64 00 FD | set_number | 380.0 | 086400 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7C 01 09 00 00 9A | set_number | 380.0 | 090000 | 2 | True | 1 | 53 00 53 | 2 | 0x017C | SP_SogliaAriaCondizionataON \| SP_SogliaDisinnescoGiri \| SP_SogliaDisinnescoMAP \| SP_SogliaDisinnescoTInj \| SP_SogliaInnescoGiri \| SP_SogliaInnescoMAP \| SP_SogliaInnescoTInj \| SP_SogliaMAPperEmulazioneContinuativa \| SP_TempoInterventoEmulazione \| SP_ValoreDiEmulazioneSensPress | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7D 01 00 F4 01 87 | set_number | 381.0 | 00f401 | 2 | True | 1 | 53 00 53 | 2 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7D 01 01 D0 07 6A | set_number | 381.0 | 01d007 | 2 | True | 1 | 53 00 53 | 2 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7D 01 02 64 00 F8 | set_number | 381.0 | 026400 | 2 | True | 1 | 53 00 53 | 2 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7D 01 03 F4 01 8A | set_number | 381.0 | 03f401 | 2 | True | 1 | 53 00 53 | 2 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7D 01 04 D0 07 6D | set_number | 381.0 | 04d007 | 2 | True | 1 | 53 00 53 | 2 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7D 01 05 64 00 FB | set_number | 381.0 | 056400 | 2 | True | 1 | 53 00 53 | 2 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7D 01 06 01 00 99 | set_number | 381.0 | 060100 | 2 | True | 1 | 53 00 53 | 2 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 14 7D 01 07 64 00 FD | set_number | 381.0 | 076400 | 2 | True | 1 | 53 00 53 | 2 | 0x017D | SP_SogliaDisinnescoGiri_CO \| SP_SogliaDisinnescoMAP_CO \| SP_SogliaDisinnescoTInj_CO \| SP_SogliaInnescoGiri_CO \| SP_SogliaInnescoMAP_CO \| SP_SogliaInnescoTInj_CO \| SP_SogliaMAPperEmulazioneContinuativa_CO \| SP_TempoInterventoEmulazione_CO | TSTRATEGIAPANDADM | TAebNumber | ack |  |  |
| 13 83 01 90 01 28 | set_number | 387.0 | 9001 | 2 | True | 1 | 53 00 53 | 2 | 0x0183 | DIFF_ENG_SPD_THD | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 84 01 C8 00 60 | set_number | 388.0 | c800 | 2 | True | 1 | 53 00 53 | 2 | 0x0184 | DELTA_ENG_SPD_THD | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 85 01 00 02 9B | set_number | 389.0 | 0002 | 2 | True | 1 | 53 00 53 | 2 | 0x0185 | DIFF_MNFLD_PRESS_THD | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 86 01 33 00 CD | set_number | 390.0 | 3300 | 2 | True | 1 | 53 00 53 | 2 | 0x0186 | DELTA_MNFLD_PRESS_THD | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 87 01 00 08 A3 | set_number | 391.0 | 0008 | 2 | True | 1 | 53 00 53 | 2 | 0x0187 | DIFF_PETR_TINJ_T_THD | TAUTOCALDM | TAebNumber | ack |  |  |
| 13 88 01 00 02 9E | set_number | 392.0 | 0002 | 2 | True | 1 | 53 00 53 | 2 | 0x0188 | DELTA_PETR_INJ_T_THD | TAUTOCALDM | TAebNumber | ack |  |  |
| 12 8B 01 00 9E | set_number | 395.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x018B | DISABLE_ACQ_BAND | TAUTOCALDM | TAebNumber | ack |  |  |
| 12 04 00 02 18 | set_number | 4.0 | 02 | 2 | True | 1 | 53 00 53 | 2 | 0x0004 | TIPO_LAMBDA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 90 01 01 A4 | set_number | 400.0 | 01 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0190 | PREHEAT_SYNC_INJ_NUM | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 12 05 00 1C 33 | set_number | 5.0 | 1c | 2 | True | 1 | 53 00 53 | 2 | 0x0005 | RIF_LAMBDA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 34 00 02 48 | set_number | 52.0 | 02 | 2 | True | 1 | 53 00 53 | 2 | 0x0034 | TIPO_INIEZIONE | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 35 00 00 00 48 | set_number | 53.0 | 0000 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 02 32 7C | set_number | 53.0 | 0232 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 03 30 7B | set_number | 53.0 | 0330 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 04 38 84 | set_number | 53.0 | 0438 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 05 20 6D | set_number | 53.0 | 0520 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 06 66 B4 | set_number | 53.0 | 0666 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 07 61 B0 | set_number | 53.0 | 0761 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 08 7A CA | set_number | 53.0 | 087a | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 09 7A CB | set_number | 53.0 | 097a | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 0A 65 B7 | set_number | 53.0 | 0a65 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 0B 6E C1 | set_number | 53.0 | 0b6e | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 0C 64 B8 | set_number | 53.0 | 0c64 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 0D 6F C4 | set_number | 53.0 | 0d6f | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 0E 20 76 | set_number | 53.0 | 0e20 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 0F 4C A3 | set_number | 53.0 | 0f4c | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 10 4F A7 | set_number | 53.0 | 104f | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 11 47 A0 | set_number | 53.0 | 1147 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 12 53 AD | set_number | 53.0 | 1253 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 13 00 5B | set_number | 53.0 | 1300 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 14 00 5C | set_number | 53.0 | 1400 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 15 00 5D | set_number | 53.0 | 1500 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 16 00 5E | set_number | 53.0 | 1600 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 17 00 5F | set_number | 53.0 | 1700 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 18 00 60 | set_number | 53.0 | 1800 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 19 00 61 | set_number | 53.0 | 1900 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 1A 00 62 | set_number | 53.0 | 1a00 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 1B 00 63 | set_number | 53.0 | 1b00 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 1C 00 64 | set_number | 53.0 | 1c00 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 13 35 00 1D 00 65 | set_number | 53.0 | 1d00 | 1 | True | 1 | 53 00 53 | 1 | 0x0035 | IDENTIFICATIVO | TSTREAMDATI | TAebVector | ack |  |  |
| 12 36 00 FF 47 | set_number | 54.0 | ff | 2 | True | 1 | 53 00 53 | 2 | 0x0036 | TEMPO_INIEZIONE_CONTINUA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 38 00 0B 55 | set_number | 56.0 | 0b | 2 | True | 1 | 53 00 53 | 2 | 0x0038 | CORRENTE_MANTENIMENTO | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 3B 00 7E 02 CE | set_number | 59.0 | 7e02 | 2 | True | 1 | 53 00 53 | 2 | 0x003B | TEMPO_GAS | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 06 00 00 18 | set_number | 6.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x0006 | RITARDO_SONDA | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 3C 00 6C 00 BB | set_number | 60.0 | 6c00 | 2 | True | 1 | 53 00 53 | 2 | 0x003C | TEMPO_BENZINA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 3E 00 00 50 | set_number | 62.0 | 00 | 2 | True | 1 | 53 00 53 | 2 | 0x003E | TEMPO_RITORNO_BENZINA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 07 00 05 1E | set_number | 7.0 | 05 | 2 | True | 1 | 53 00 53 | 2 | 0x0007 | TEMPO_LBD_FREDDA | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 46 00 33 8B | set_number | 70.0 | 33 | 2 | True | 1 | 53 00 53 | 2 | 0x0046 | SOGLIA_RICCO_FORZATO | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 47 00 29 82 | set_number | 71.0 | 29 | 2 | True | 1 | 53 00 53 | 2 | 0x0047 | LIVELLO_EMUL_ALTO | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 48 00 05 5F | set_number | 72.0 | 05 | 2 | True | 1 | 53 00 53 | 2 | 0x0048 | LIVELLO_EMUL_BASSO | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 49 00 64 08 C8 | set_number | 73.0 | 6408 | 2 | True | 1 | 53 00 53 | 2 | 0x0049 | TEMPO_CORRENTE_CUTOFF | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 4B 00 E8 03 49 | set_number | 75.0 | e803 | 2 | True | 1 | 53 00 53 | 2 | 0x004B | CILINDRATA | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 4F 00 00 00 62 | set_number | 79.0 | 0000 | 2 | True | 1 | 53 00 53 | 2 | 0x004F | PARAM_INJ | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 08 00 1F 39 | set_number | 8.0 | 1f | 2 | True | 1 | 53 00 53 | 2 | 0x0008 | RIF_SUP_LAMBDA_FREDDA | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 52 00 0D 03 75 | set_number | 82.0 | 0d03 | 2 | True | 1 | 53 00 53 | 2 | 0x0052 | TEMPO_CHIUSURA_INIETTORE | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 53 00 D1 03 3A | set_number | 83.0 | d103 | 2 | True | 1 | 53 00 53 | 2 | 0x0053 | TEMPO_APERTURA_INIETTORE | TSTREAMDATI | TAebNumber | ack |  |  |
| 14 54 00 00 09 AE 1F | set_number | 84.0 | 0009ae | 1 | True | 1 | 53 00 53 | 1 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack |  |  |
| 14 54 00 00 0A 93 05 | set_number | 84.0 | 000a93 | 1 | True | 1 | 53 00 53 | 1 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack |  |  |
| 14 54 00 00 0A AB 1D | set_number | 84.0 | 000aab | 1 | True | 1 | 53 00 53 | 1 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack |  |  |
| 14 54 00 00 0A AF 21 | set_number | 84.0 | 000aaf | 1 | True | 1 | 53 00 53 | 1 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack |  |  |
| 14 54 00 00 0A FF 71 | set_number | 84.0 | 000aff | 1 | True | 1 | 53 00 53 | 1 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack |  |  |
| 14 54 00 07 02 B5 26 | set_number | 84.0 | 0702b5 | 1 | True | 1 | 53 00 53 | 1 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack |  |  |
| 14 54 00 07 02 B7 28 | set_number | 84.0 | 0702b7 | 1 | True | 1 | 53 00 53 | 1 | 0x0054 | MAP_K | TSTREAMDATI | TAebMatrix | ack |  |  |
| 13 55 00 28 08 98 | set_number | 85.0 | 2808 | 1 | True | 1 | 53 00 53 | 1 | 0x0055 | TEMPO_GAS_PARZIALE | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 55 00 29 08 99 | set_number | 85.0 | 2908 | 1 | True | 1 | 53 00 53 | 1 | 0x0055 | TEMPO_GAS_PARZIALE | TSTREAMDATI | TAebNumber | ack |  |  |
| 13 58 00 38 04 A7 | set_number | 88.0 | 3804 | 2 | True | 1 | 53 00 53 | 2 | 0x0058 | TEMPO_TAGLIANDI | TSTREAMDATI | TAebNumber | ack |  |  |
| 12 09 00 0F 2A | set_number | 9.0 | 0f | 2 | True | 1 | 53 00 53 | 2 | 0x0009 | RIF_INF_LAMBDA_FREDDA | TSTREAMDATI | TAebNumber | ack |  |  |
| 33 68 00 00 00 9B | set_vector_or_matrix | 104.0 | 0000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0068 | RIF_PRESS_ASS_LR \| TEMP_ACQUA_MONOFUEL | TSTREAMDATI | TAebVector | ca_status | 01 10 |  |
| 36 8A 00 12 5C 05 EC 1E 3D | set_vector_or_matrix | 138.0 | 125c05ec1e | 2 | True | 1 | 53 00 53 | 2 | 0x008A | PARAMETRI_TEMP | TSTREAMDATI | TAebVector | ack |  |  |
| 36 8F 00 00 00 00 00 00 C5 | set_vector_or_matrix | 143.0 | 0000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 8F 00 01 00 00 00 00 C6 | set_vector_or_matrix | 143.0 | 0100000000 | 2 | True | 1 | 53 00 53 | 2 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 8F 00 02 00 00 00 00 C7 | set_vector_or_matrix | 143.0 | 0200000000 | 2 | True | 1 | 53 00 53 | 2 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 8F 00 03 00 00 00 00 C8 | set_vector_or_matrix | 143.0 | 0300000000 | 2 | True | 1 | 53 00 53 | 2 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 8F 00 04 00 00 00 00 C9 | set_vector_or_matrix | 143.0 | 0400000000 | 2 | True | 1 | 53 00 53 | 2 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 8F 00 05 00 00 00 00 CA | set_vector_or_matrix | 143.0 | 0500000000 | 2 | True | 1 | 53 00 53 | 2 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 8F 00 06 00 00 00 00 CB | set_vector_or_matrix | 143.0 | 0600000000 | 2 | True | 1 | 53 00 53 | 2 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 8F 00 07 00 00 00 00 CC | set_vector_or_matrix | 143.0 | 0700000000 | 2 | True | 1 | 53 00 53 | 2 | 0x008F | TINJ_3000RPM | TSTREAMDATI | TAebMatrix | ack |  |  |
| 35 91 00 27 00 00 00 ED | set_vector_or_matrix | 145.0 | 27000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0091 | SCARTO_MINIMO_TARATURA | TSTREAMDATI | TAebVector | ack |  |  |
| 36 95 00 00 00 00 00 00 CB | set_vector_or_matrix | 149.0 | 0000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0095 | MAPPA_CORR_TARATURA | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 95 00 01 00 00 00 00 CC | set_vector_or_matrix | 149.0 | 0100000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0095 | MAPPA_CORR_TARATURA | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 95 00 02 00 00 00 00 CD | set_vector_or_matrix | 149.0 | 0200000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0095 | MAPPA_CORR_TARATURA | TSTREAMDATI | TAebMatrix | ack |  |  |
| 36 95 00 03 00 00 00 00 CE | set_vector_or_matrix | 149.0 | 0300000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0095 | MAPPA_CORR_TARATURA | TSTREAMDATI | TAebMatrix | ack |  |  |
| 34 97 00 01 05 02 D3 | set_vector_or_matrix | 151.0 | 010502 | 2 | True | 1 | 53 00 53 | 2 | 0x0097 | PARAM_AUTOTARATURA | TSTREAMDATI | TAebVector | ack |  |  |
| 37 4B 3E 01 00 01 00 02 00 03 00 04 00 05 00 06 00 07 00 08 00 | set_vector_or_matrix | 15947.0 | 0100010002000300040005000600070008 | 2 | False | 1 | 09 53 00 53 | 2 | 0x3E4B |  |  |  | bad_checksum |  |  |
| 37 61 3E 01 5E 32 5E 32 5E 32 5E 32 5E 32 5E 32 42 38 F2 3A 6A | set_vector_or_matrix | 15969.0 | 015e325e325e325e325e325e324238f23a | 2 | False | 1 | 3C 53 00 53 | 2 | 0x3E61 |  |  |  | bad_checksum |  |  |
| 35 A1 00 00 00 34 21 2B | set_vector_or_matrix | 161.0 | 00003421 | 2 | True | 1 | 53 00 53 | 2 | 0x00A1 | GIRI_PER_BENZINA \| SEQUENZA_INJ_BENZ_LR | TSTREAMDATI | TAebVector | ack |  |  |
| 33 A3 00 14 05 EF | set_vector_or_matrix | 163.0 | 1405 | 2 | True | 1 | 53 00 53 | 2 | 0x00A3 | INIETTATE_PER_BENZINA \| RIF_MAP_ANTICIPO_LR | TSTREAMDATI | TAebVector | ack |  |  |
| 33 AA 00 05 24 06 | set_vector_or_matrix | 170.0 | 0524 | 2 | True | 1 | 53 00 53 | 2 | 0x00AA | EMULAZIONE_POSTERIORE | TSTREAMDATI | TAebVector | ack |  |  |
| 35 B3 00 00 00 00 00 E8 | set_vector_or_matrix | 179.0 | 00000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00B3 | CHANGE_OVER | TSTREAMDATI | TAebVector | ca_status | 01 10 |  |
| 33 B9 00 00 64 50 | set_vector_or_matrix | 185.0 | 0064 | 2 | True | 1 | CA 01 10 DB | 2 | 0x00B9 | CONFIGURA_ADATTA | TSTREAMDATI | TAebVector | ca_status | 01 10 |  |
| 35 C0 00 01 00 00 00 F6 | set_vector_or_matrix | 192.0 | 01000000 | 2 | True | 1 | 53 00 53 | 2 | 0x00C0 | FLAG_CONF2 | TSTREAMDATI | TAebVector | ack |  |  |
| 37 1F 08 00 00 7B 00 00 00 00 D9 | set_vector_or_matrix | 2079.0 | 00007b00000000 | 2 | True | 1 | 53 00 53 | 2 | 0x081F |  |  |  | ack |  |  |
| 37 1F 08 00 01 00 00 00 00 00 5F | set_vector_or_matrix | 2079.0 | 00010000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x081F |  |  |  | ack |  |  |
| 37 1F 08 00 02 00 00 00 00 00 60 | set_vector_or_matrix | 2079.0 | 00020000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x081F |  |  |  | ack |  |  |
| 37 9B 08 00 00 00 00 00 27 00 01 | set_vector_or_matrix | 2203.0 | 00000000002700 | 2 | True | 1 | 53 00 53 | 2 | 0x089B |  |  |  | ack |  |  |
| 35 E7 00 C3 F7 F7 F7 C4 | set_vector_or_matrix | 231.0 | c3f7f7f7 | 2 | True | 1 | 53 00 53 | 2 | 0x00E7 | ADVANCED_TEMP_RID | TSTREAMDATI | TAebVector | ack |  |  |
| 35 E8 00 08 07 00 00 2C | set_vector_or_matrix | 232.0 | 08070000 | 2 | True | 1 | 53 00 53 | 2 | 0x00E8 | ADVANCED_PRESS_BACK | TSTREAMDATI | TAebVector | ack |  |  |
| 37 34 09 01 00 00 00 04 00 F4 01 6E | set_vector_or_matrix | 2356.0 | 010000000400f401 | 2 | True | 1 | 53 00 53 | 2 | 0x0934 |  |  |  | ack |  |  |
| 37 34 09 01 01 14 00 04 00 F4 01 83 | set_vector_or_matrix | 2356.0 | 010114000400f401 | 2 | True | 1 | 53 00 53 | 2 | 0x0934 |  |  |  | ack |  |  |
| 37 34 09 01 02 14 00 04 00 F4 01 84 | set_vector_or_matrix | 2356.0 | 010214000400f401 | 2 | True | 1 | 53 00 53 | 2 | 0x0934 |  |  |  | ack |  |  |
| 37 34 09 01 03 19 00 04 00 F4 01 8A | set_vector_or_matrix | 2356.0 | 010319000400f401 | 2 | True | 1 | 53 00 53 | 2 | 0x0934 |  |  |  | ack |  |  |
| 34 ED 00 00 00 FF 20 | set_vector_or_matrix | 237.0 | 0000ff | 2 | True | 1 | 53 00 53 | 2 | 0x00ED | PARAMETRI_TAGLIANDI | TSTREAMDATI | TAebVector | ack |  |  |
| 33 EE 00 00 32 53 | set_vector_or_matrix | 238.0 | 0032 | 2 | True | 1 | 53 00 53 | 2 | 0x00EE | TEMPI_ANTICIPI_EV | TSTREAMDATI | TAebVector | ack |  |  |
| 35 FA 00 00 00 00 00 2F | set_vector_or_matrix | 250.0 | 00000000 | 2 | True | 1 | 53 00 53 | 2 | 0x00FA | FLAG_CONF3 | TSTREAMDATI | TAebVector | ack |  |  |
| 37 EB 09 00 00 00 00 00 00 00 00 2B | set_vector_or_matrix | 2539.0 | 0000000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 01 00 00 00 00 00 00 2C | set_vector_or_matrix | 2539.0 | 0001000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 02 00 00 00 00 00 00 2D | set_vector_or_matrix | 2539.0 | 0002000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 03 00 00 00 00 00 00 2E | set_vector_or_matrix | 2539.0 | 0003000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 04 00 00 00 00 00 00 2F | set_vector_or_matrix | 2539.0 | 0004000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 05 00 00 00 00 00 00 30 | set_vector_or_matrix | 2539.0 | 0005000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 06 00 00 00 00 00 00 31 | set_vector_or_matrix | 2539.0 | 0006000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 07 00 00 00 00 00 00 32 | set_vector_or_matrix | 2539.0 | 0007000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 08 00 00 00 00 00 00 33 | set_vector_or_matrix | 2539.0 | 0008000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 09 00 00 00 00 00 00 34 | set_vector_or_matrix | 2539.0 | 0009000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 0A 00 00 00 00 00 00 35 | set_vector_or_matrix | 2539.0 | 000a000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 EB 09 00 0B 00 00 00 00 00 00 36 | set_vector_or_matrix | 2539.0 | 000b000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x09EB |  |  |  | ca_status | 01 10 |  |
| 37 27 0A 00 00 00 00 00 00 00 00 00 68 | set_vector_or_matrix | 2599.0 | 000000000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0A27 |  |  |  | ca_status | 01 10 |  |
| 37 32 0A 01 00 02 1E 00 00 00 00 00 94 | set_vector_or_matrix | 2610.0 | 0100021e0000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0A32 |  |  |  | ca_status | 01 10 |  |
| 37 3C 0A 01 33 09 CD 07 00 0C 00 16 B0 | set_vector_or_matrix | 2620.0 | 013309cd07000c0016 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0A3C |  |  |  | ca_status | 01 10 |  |
| 37 6F 0A 00 90 01 58 02 20 03 E8 03 A9 | set_vector_or_matrix | 2671.0 | 00900158022003e803 | 2 | True | 1 | 53 00 53 | 2 | 0x0A6F |  |  |  | ack |  |  |
| 37 84 0A 00 A1 07 43 0F E4 16 85 1E 5C | set_vector_or_matrix | 2692.0 | 00a107430fe416851e | 2 | True | 1 | CA 01 10 DB | 2 | 0x0A84 |  |  |  | ca_status | 01 10 |  |
| 37 A0 0A 00 C7 2D 00 00 00 00 C7 2D C9 | set_vector_or_matrix | 2720.0 | 00c72d00000000c72d | 2 | True | 1 | 53 00 53 | 2 | 0x0AA0 |  |  |  | ack |  |  |
| 37 C6 0A 00 4A 02 3A 00 94 04 55 00 7A | set_vector_or_matrix | 2758.0 | 004a023a0094045500 | 2 | True | 1 | 53 00 53 | 2 | 0x0AC6 |  |  |  | ack |  |  |
| 37 DD 0A 00 0F 14 19 1E 28 2D 32 32 31 | set_vector_or_matrix | 2781.0 | 000f14191e282d3232 | 2 | True | 1 | 53 00 53 | 2 | 0x0ADD |  |  |  | ack |  |  |
| 37 E2 0A 00 00 00 00 00 00 00 00 00 23 | set_vector_or_matrix | 2786.0 | 000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0AE2 |  |  |  | ack |  |  |
| 36 1C 00 71 0B F0 05 00 C3 | set_vector_or_matrix | 28.0 | 710bf00500 | 2 | True | 1 | 53 00 53 | 2 | 0x001C | ABIL_DIAGNOSI | TSTREAMDATI | TAebVector | ack |  |  |
| 37 F8 0A 00 A8 00 04 00 50 46 10 0E 99 | set_vector_or_matrix | 2808.0 | 00a80004005046100e | 2 | True | 1 | 53 00 53 | 2 | 0x0AF8 |  |  |  | ack |  |  |
| 37 0D 0B 00 00 00 01 02 B6 B6 B6 B6 B6 E0 | set_vector_or_matrix | 2829.0 | 0000000102b6b6b6b6b6 | 2 | True | 1 | 53 00 53 | 2 | 0x0B0D |  |  |  | ack |  |  |
| 37 0D 0B 00 01 01 02 0C 00 00 00 00 00 5F | set_vector_or_matrix | 2829.0 | 000101020c0000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0B0D |  |  |  | ack |  |  |
| 37 2B 0B 00 64 63 61 5E 5B 59 56 52 50 9F | set_vector_or_matrix | 2859.0 | 006463615e5b59565250 | 2 | True | 1 | 53 00 53 | 2 | 0x0B2B |  |  |  | ack |  |  |
| 37 2C 0B 00 00 00 00 00 00 00 00 00 00 6E | set_vector_or_matrix | 2860.0 | 00000000000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0B2C |  |  |  | ca_status | 01 10 |  |
| 37 2C 0B 00 01 00 00 00 00 00 00 00 00 6F | set_vector_or_matrix | 2860.0 | 00010000000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0B2C |  |  |  | ca_status | 01 10 |  |
| 37 2C 0B 00 02 00 00 00 00 00 00 00 00 70 | set_vector_or_matrix | 2860.0 | 00020000000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0B2C |  |  |  | ca_status | 01 10 |  |
| 37 2C 0B 00 03 00 00 00 00 00 00 00 00 71 | set_vector_or_matrix | 2860.0 | 00030000000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0B2C |  |  |  | ca_status | 01 10 |  |
| 37 2C 0B 00 04 00 00 00 00 00 00 00 00 72 | set_vector_or_matrix | 2860.0 | 00040000000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0B2C |  |  |  | ca_status | 01 10 |  |
| 37 2F 0B 00 E7 D7 C3 B6 A9 9B 8D 71 58 42 | set_vector_or_matrix | 2863.0 | 00e7d7c3b6a99b8d7158 | 2 | True | 1 | 53 00 53 | 2 | 0x0B2F |  |  |  | ack |  |  |
| 36 1D 00 00 00 00 00 00 53 | set_vector_or_matrix | 29.0 | 0000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x001D | STATO_DIAGNOSI | TSTREAMDATI | TAebVector | ack |  |  |
| 37 5D 0B 00 6B 69 67 65 64 62 61 5E 5C 20 | set_vector_or_matrix | 2909.0 | 006b6967656462615e5c | 2 | True | 1 | 53 00 53 | 2 | 0x0B5D |  |  |  | ack |  |  |
| 35 03 00 86 24 51 10 43 | set_vector_or_matrix | 3.0 | 86245110 | 4 | True | 1 | 53 00 53 | 4 | 0x0003 | FLAG_CONF1 | TSTREAMDATI | TAebVector | ack |  |  |
| 35 03 00 86 2C 51 10 4B | set_vector_or_matrix | 3.0 | 862c5110 | 5 | True | 1 | 53 00 53 | 5 | 0x0003 | FLAG_CONF1 | TSTREAMDATI | TAebVector | ack |  |  |
| 35 03 00 86 34 51 10 53 | set_vector_or_matrix | 3.0 | 86345110 | 3 | True | 1 | 53 00 53 | 3 | 0x0003 | FLAG_CONF1 | TSTREAMDATI | TAebVector | ack |  |  |
| 35 03 00 86 3C 51 10 5B | set_vector_or_matrix | 3.0 | 863c5110 | 2 | True | 1 | 53 00 53 | 2 | 0x0003 | FLAG_CONF1 | TSTREAMDATI | TAebVector | ack |  |  |
| 37 DC 0B 00 00 26 32 43 58 71 8D A9 FF B7 | set_vector_or_matrix | 3036.0 | 000026324358718da9ff | 2 | True | 1 | 53 00 53 | 2 | 0x0BDC |  |  |  | ack |  |  |
| 37 0C 0C 01 88 13 F4 01 0A 00 E8 03 14 00 E9 | set_vector_or_matrix | 3084.0 | 018813f4010a00e8031400 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0C0C |  |  |  | ca_status | 01 10 |  |
| 37 2A 0C 00 00 26 32 3A 43 4D 53 58 64 FF 9D | set_vector_or_matrix | 3114.0 | 000026323a434d535864ff | 2 | True | 1 | 53 00 53 | 2 | 0x0C2A |  |  |  | ack |  |  |
| 37 2E 0C 00 00 FF F0 96 69 4B 3C 2D 1E 0F 40 | set_vector_or_matrix | 3118.0 | 0000fff096694b3c2d1e0f | 2 | True | 1 | 53 00 53 | 2 | 0x0C2E |  |  |  | ack |  |  |
| 37 2E 0C 00 01 E1 E1 B4 96 78 5A 3C 3C 2D F5 | set_vector_or_matrix | 3118.0 | 0001e1e1b496785a3c3c2d | 2 | True | 1 | 53 00 53 | 2 | 0x0C2E |  |  |  | ack |  |  |
| 37 33 0C 01 40 06 64 00 DC 05 02 00 14 00 18 | set_vector_or_matrix | 3123.0 | 0140066400dc0502001400 | 2 | True | 1 | 53 00 53 | 2 | 0x0C33 |  |  |  | ack |  |  |
| 37 3D 0C 01 00 20 00 28 00 30 00 38 00 40 71 | set_vector_or_matrix | 3133.0 | 0100200028003000380040 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0C3D |  |  |  | ca_status | 01 10 |  |
| 37 5C 0C 00 00 18 26 32 43 58 71 9B C3 FF 78 | set_vector_or_matrix | 3164.0 | 00001826324358719bc3ff | 2 | True | 1 | 53 00 53 | 2 | 0x0C5C |  |  |  | ack |  |  |
| 37 72 0C 01 01 03 03 01 03 03 01 03 03 01 CC | set_vector_or_matrix | 3186.0 | 0101030301030301030301 | 2 | True | 1 | 53 00 53 | 2 | 0x0C72 |  |  |  | ack |  |  |
| 37 9E 0C 01 37 00 90 01 00 00 C8 00 AC 0D 2B | set_vector_or_matrix | 3230.0 | 01370090010000c800ac0d | 2 | True | 1 | CA 01 10 DB | 2 | 0x0C9E |  |  |  | ca_status | 01 10 |  |
| 37 C4 0C 00 2A 2C 2E 30 32 34 36 38 3A 3C 05 | set_vector_or_matrix | 3268.0 | 002a2c2e30323436383a3c | 2 | True | 1 | 53 00 53 | 2 | 0x0CC4 |  |  |  | ack |  |  |
| 37 C5 0C 00 00 00 00 00 00 00 00 00 00 00 08 | set_vector_or_matrix | 3269.0 | 0000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0CC5 |  |  |  | ack |  |  |
| 37 E9 0C 00 08 05 05 03 03 02 00 00 00 00 46 | set_vector_or_matrix | 3305.0 | 0008050503030200000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0CE9 |  |  |  | ca_status | 01 10 |  |
| 37 F2 0C 00 00 00 00 00 00 00 00 00 00 00 35 | set_vector_or_matrix | 3314.0 | 0000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0CF2 |  |  |  | ack |  |  |
| 37 F3 0C 00 00 00 00 00 00 00 00 00 00 00 36 | set_vector_or_matrix | 3315.0 | 0000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0CF3 |  |  |  | ack |  |  |
| 37 3E 0D 01 00 14 2A 85 1B AE 0F A4 08 71 01 3C | set_vector_or_matrix | 3390.0 | 0100142a851bae0fa4087101 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0D3E |  |  |  | ca_status | 01 10 |  |
| 37 3E 0D 01 01 00 28 F6 1C CD 10 71 09 B8 02 CF | set_vector_or_matrix | 3390.0 | 01010028f61ccd107109b802 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0D3E |  |  |  | ca_status | 01 10 |  |
| 37 3E 0D 01 02 F6 24 71 1D C3 11 71 09 33 03 B1 | set_vector_or_matrix | 3390.0 | 0102f624711dc31171093303 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0D3E |  |  |  | ca_status | 01 10 |  |
| 37 3E 0D 01 03 F6 24 66 1E 48 11 8F 0A AE 03 C7 | set_vector_or_matrix | 3390.0 | 0103f624661e48118f0aae03 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0D3E |  |  |  | ca_status | 01 10 |  |
| 37 73 0E 00 00 00 00 00 00 00 00 00 00 00 00 00 B8 | set_vector_or_matrix | 3699.0 | 00000000000000000000000000 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0E73 |  |  |  | ca_status | 01 10 |  |
| 35 25 00 27 5D 8F DB 48 | set_vector_or_matrix | 37.0 | 275d8fdb | 2 | True | 1 | 53 00 53 | 2 | 0x0025 | RIF_SENSORE | TSTREAMDATI | TAebVector | ack |  |  |
| 37 78 0E 00 64 00 F4 01 64 00 F4 01 23 00 3A 03 CF | set_vector_or_matrix | 3704.0 | 006400f4016400f40123003a03 | 2 | True | 1 | 53 00 53 | 2 | 0x0E78 |  |  |  | ack |  |  |
| 37 82 0E 00 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A FF | set_vector_or_matrix | 3714.0 | 001a1a1a1a1a1a1a1a1a1a1a1a | 2 | True | 1 | 53 00 53 | 2 | 0x0E82 |  |  |  | ack |  |  |
| 37 9E 0E 00 00 00 00 00 00 00 00 00 00 00 00 00 E3 | set_vector_or_matrix | 3742.0 | 00000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0E9E |  |  |  | ack |  |  |
| 36 79 01 FF FF FF FF FF AB | set_vector_or_matrix | 377.0 | ffffffffff | 2 | True | 1 | 53 00 53 | 2 | 0x0179 | ABIL_FREEZEFRAME | TSTREAMDATI | TAebVector | ack |  |  |
| 37 DB 0E 00 FC 08 16 00 00 00 00 00 74 00 00 00 AE | set_vector_or_matrix | 3803.0 | 00fc0816000000000074000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0EDB |  |  |  | ack |  |  |
| 37 54 0F 00 00 B6 B5 B1 B5 B3 B5 B3 B3 AC AE AF AB ED | set_vector_or_matrix | 3924.0 | 0000b6b5b1b5b3b5b3b3acaeafab | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 01 B6 B5 B3 B5 B3 B5 B5 B8 B6 AD AE AE 02 | set_vector_or_matrix | 3924.0 | 0001b6b5b3b5b3b5b5b8b6adaeae | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 02 B8 B7 B5 B7 B8 B4 B3 AB AD AC AC AC F2 | set_vector_or_matrix | 3924.0 | 0002b8b7b5b7b8b4b3abadacacac | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 03 B6 B6 B6 B8 B8 B3 B5 A8 AE AF AB AB F2 | set_vector_or_matrix | 3924.0 | 0003b6b6b6b8b8b3b5a8aeafabab | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 04 BC B4 B4 BC B8 B5 B3 B4 AD AA AD AE 04 | set_vector_or_matrix | 3924.0 | 0004bcb4b4bcb8b5b3b4adaaadae | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 05 BC B9 BA BA B8 B7 B4 AD AD AF AB AC 0B | set_vector_or_matrix | 3924.0 | 0005bcb9babab8b7b4adadafabac | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 06 B7 B8 B4 B8 B8 B8 B1 B0 B1 B0 AE AE 09 | set_vector_or_matrix | 3924.0 | 0006b7b8b4b8b8b8b1b0b1b0aeae | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 07 B7 B7 B5 B9 B6 B7 B8 BE BF C0 AC AC 37 | set_vector_or_matrix | 3924.0 | 0007b7b7b5b9b6b7b8bebfc0acac | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 08 B7 B6 B4 B5 B6 BA B4 BD BC BC AF AF 2F | set_vector_or_matrix | 3924.0 | 0008b7b6b4b5b6bab4bdbcbcafaf | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 09 B7 B7 BA BF B9 B7 B7 BF BE BA B1 B1 4A | set_vector_or_matrix | 3924.0 | 0009b7b7babfb9b7b7bfbebab1b1 | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 0A B2 B5 BA BC B7 B6 B8 BA BD BD AE AE 36 | set_vector_or_matrix | 3924.0 | 000ab2b5babcb7b6b8babdbdaeae | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 0B B5 B6 B6 BF BE B3 B9 C0 C0 BA AB AB 3F | set_vector_or_matrix | 3924.0 | 000bb5b6b6bfbeb3b9c0c0baabab | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 54 0F 00 0C 6E 6E 6E 6E 6E 6E 70 71 72 73 74 74 E8 | set_vector_or_matrix | 3924.0 | 000c6e6e6e6e6e6e707172737474 | 2 | True | 1 | 53 00 53 | 2 | 0x0F54 |  |  |  | ack |  |  |
| 37 70 0F 00 00 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A EE | set_vector_or_matrix | 3952.0 | 00001a1a1a1a1a1a1a1a1a1a1a1a | 2 | True | 1 | 53 00 53 | 2 | 0x0F70 |  |  |  | ack |  |  |
| 37 70 0F 00 01 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A EF | set_vector_or_matrix | 3952.0 | 00011a1a1a1a1a1a1a1a1a1a1a1a | 2 | True | 1 | 53 00 53 | 2 | 0x0F70 |  |  |  | ack |  |  |
| 37 70 0F 00 02 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A 1A F0 | set_vector_or_matrix | 3952.0 | 00021a1a1a1a1a1a1a1a1a1a1a1a | 2 | True | 1 | 53 00 53 | 2 | 0x0F70 |  |  |  | ack |  |  |
| 37 71 0F 00 00 29 2D 31 33 31 31 31 31 31 31 31 31 F9 | set_vector_or_matrix | 3953.0 | 0000292d31333131313131313131 | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 01 2D 32 36 38 35 35 35 35 35 35 35 35 2D | set_vector_or_matrix | 3953.0 | 00012d3236383535353535353535 | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 02 32 36 3A 3C 3A 3A 3A 3A 3A 3A 3A 3A 67 | set_vector_or_matrix | 3953.0 | 000232363a3c3a3a3a3a3a3a3a3a | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 03 36 3B 3F 42 3F 3F 3F 3F 3F 3F 3F 3F A4 | set_vector_or_matrix | 3953.0 | 0003363b3f423f3f3f3f3f3f3f3f | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 04 39 3F 44 47 44 44 44 44 44 44 44 44 DE | set_vector_or_matrix | 3953.0 | 0004393f44474444444444444444 | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 05 3D 43 48 4D 4A 4A 4A 4A 4A 4A 4A 4A 21 | set_vector_or_matrix | 3953.0 | 00053d43484d4a4a4a4a4a4a4a4a | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 06 41 47 4D 53 4F 4F 4F 4F 4F 4F 4F 4F 5D | set_vector_or_matrix | 3953.0 | 000641474d534f4f4f4f4f4f4f4f | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 07 46 4D 52 5A 56 56 56 56 56 56 56 56 AD | set_vector_or_matrix | 3953.0 | 0007464d525a5656565656565656 | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 08 4A 52 58 61 5D 5D 5D 5D 5D 5D 5D 5D FC | set_vector_or_matrix | 3953.0 | 00084a5258615d5d5d5d5d5d5d5d | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 09 50 57 5E 67 62 62 62 62 62 62 62 62 3C | set_vector_or_matrix | 3953.0 | 000950575e676262626262626262 | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 0A 55 5C 63 6B 67 67 67 67 67 67 67 67 78 | set_vector_or_matrix | 3953.0 | 000a555c636b6767676767676767 | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 71 0F 00 0B 5A 61 67 6E 6A 6A 6A 6A 6A 6A 6A 6A A2 | set_vector_or_matrix | 3953.0 | 000b5a61676e6a6a6a6a6a6a6a6a | 2 | True | 1 | 53 00 53 | 2 | 0x0F71 |  |  |  | ack |  |  |
| 37 D0 0F 00 00 00 00 00 00 00 00 00 00 00 00 00 00 16 | set_vector_or_matrix | 4048.0 | 0000000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 01 00 00 00 00 00 00 00 00 00 00 00 00 17 | set_vector_or_matrix | 4048.0 | 0001000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 02 00 00 00 00 00 00 00 00 00 00 00 00 18 | set_vector_or_matrix | 4048.0 | 0002000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 03 00 00 00 00 00 00 00 00 00 00 00 00 19 | set_vector_or_matrix | 4048.0 | 0003000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 04 00 00 00 00 00 00 00 00 00 00 00 00 1A | set_vector_or_matrix | 4048.0 | 0004000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 05 00 00 00 00 00 00 00 00 00 00 00 00 1B | set_vector_or_matrix | 4048.0 | 0005000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 06 00 00 00 00 00 00 00 00 00 00 00 00 1C | set_vector_or_matrix | 4048.0 | 0006000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 07 00 00 00 00 00 00 00 00 00 00 00 00 1D | set_vector_or_matrix | 4048.0 | 0007000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 08 00 00 00 00 00 00 00 00 00 00 00 00 1E | set_vector_or_matrix | 4048.0 | 0008000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 09 00 00 00 00 00 00 00 00 00 00 00 00 1F | set_vector_or_matrix | 4048.0 | 0009000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 0A 00 00 00 00 00 00 00 00 00 00 00 00 20 | set_vector_or_matrix | 4048.0 | 000a000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D0 0F 00 0B 00 00 00 00 00 00 00 00 00 00 00 00 21 | set_vector_or_matrix | 4048.0 | 000b000000000000000000000000 | 2 | True | 1 | 53 00 53 | 2 | 0x0FD0 |  |  |  | ack |  |  |
| 37 D7 0F 00 00 E8 03 D0 07 B8 0B A0 0F 88 13 70 17 73 | set_vector_or_matrix | 4055.0 | 0000e803d007b80ba00f88137017 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FD7 |  |  |  | ca_status | 01 10 |  |
| 37 D7 0F 00 01 40 01 C2 01 26 02 8A 02 EE 02 8E 03 57 | set_vector_or_matrix | 4055.0 | 00014001c20126028a02ee028e03 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FD7 |  |  |  | ca_status | 01 10 |  |
| 37 D7 0F 00 02 0D 03 A1 07 35 0C C9 10 5D 15 F1 19 6D | set_vector_or_matrix | 4055.0 | 00020d03a107350cc9105d15f119 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FD7 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 00 77 79 7B 7B 7E 7F 7E 7B 79 79 79 79 F6 | set_vector_or_matrix | 4080.0 | 000077797b7b7e7f7e7b79797979 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 01 77 78 79 7A 7D 7E 7E 7D 7C 7B 7B 7B FC | set_vector_or_matrix | 4080.0 | 00017778797a7d7e7e7d7c7b7b7b | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 02 78 79 79 7F 80 83 81 7E 7F 80 80 80 22 | set_vector_or_matrix | 4080.0 | 00027879797f8083817e7f808080 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 03 80 81 80 82 85 86 84 82 83 85 85 85 5F | set_vector_or_matrix | 4080.0 | 0003808180828586848283858585 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 04 85 86 83 86 88 88 86 85 87 89 88 88 89 | set_vector_or_matrix | 4080.0 | 0004858683868888868587898888 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 05 84 85 83 85 84 85 83 84 87 88 87 87 79 | set_vector_or_matrix | 4080.0 | 0005848583858485838487888787 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 06 7F 80 7C 7F 7D 7E 80 82 83 85 86 86 47 | set_vector_or_matrix | 4080.0 | 00067f807c7f7d7e808283858686 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 07 7B 7C 7B 7C 7B 7E 81 81 82 85 86 86 39 | set_vector_or_matrix | 4080.0 | 00077b7c7b7c7b7e818182858686 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 08 79 7A 78 79 7A 7C 80 80 82 83 84 84 25 | set_vector_or_matrix | 4080.0 | 0008797a78797a7c808082838484 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 09 6E 6F 6D 6F 72 74 77 7A 7A 7B 7C 7C BC | set_vector_or_matrix | 4080.0 | 00096e6f6d6f7274777a7a7b7c7c | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 0A 5E 5E 63 66 6B 6F 73 76 77 79 79 79 6A | set_vector_or_matrix | 4080.0 | 000a5e5e63666b6f737677797979 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 0B 5E 5E 63 66 6B 6F 73 76 77 79 79 79 6B | set_vector_or_matrix | 4080.0 | 000b5e5e63666b6f737677797979 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 37 F0 0F 00 0C 6E 6E 6E 6E 6E 6E 70 71 72 73 74 74 84 | set_vector_or_matrix | 4080.0 | 000c6e6e6e6e6e6e707172737474 | 2 | True | 1 | CA 01 10 DB | 2 | 0x0FF0 |  |  |  | ca_status | 01 10 |  |
| 36 2D 00 00 15 29 3E 52 31 | set_vector_or_matrix | 45.0 | 0015293e52 | 2 | True | 1 | CA 01 10 DB | 2 | 0x002D | MAP_ANTICIPO | TSTREAMDATI | TAebVector | ca_status | 01 10 |  |
| 37 DF 11 00 3A 3D 41 44 46 48 49 4C 4E 50 51 52 53 54 55 83 | set_vector_or_matrix | 4575.0 | 003a3d41444648494c4e505152535455 | 2 | True | 1 | 53 00 53 | 2 | 0x11DF |  |  |  | ack |  |  |
| 37 26 12 00 B6 03 E2 04 D6 06 CA 08 BE 0A B2 0C 8E 12 82 14 78 | set_vector_or_matrix | 4646.0 | 00b603e204d606ca08be0ab20c8e128214 | 2 | True | 1 | CA 01 10 DB | 2 | 0x1226 |  |  |  | ca_status | 01 10 |  |
| 37 98 12 00 E8 03 D1 03 35 0C 84 1E 94 04 4F 12 18 23 84 1E 59 | set_vector_or_matrix | 4760.0 | 00e803d103350c841e94044f121823841e | 2 | True | 1 | 53 00 53 | 2 | 0x1298 |  |  |  | ack |  |  |
| 35 32 00 00 00 D1 03 3B | set_vector_or_matrix | 50.0 | 0000d103 | 2 | True | 1 | 53 00 53 | 2 | 0x0032 | GIRI_CUTOFF_LR \| GIRI_TEMPO_CUTOFF | TSTREAMDATI | TAebNumber \| TAebVector | ack |  |  |
| 37 00 16 00 34 5A 30 33 78 41 63 67 48 62 37 46 75 30 72 59 65 | set_vector_or_matrix | 5632.0 | 00345a3033784163674862374675307259 | 2 | False | 1 | 6A 53 00 53 | 2 | 0x1600 |  |  |  | bad_checksum |  |  |
| 37 2D 16 01 35 28 46 01 5C 00 00 69 46 3D 28 69 00 35 28 69 00 | set_vector_or_matrix | 5677.0 | 01352846015c000069463d286900352869 | 2 | False | 1 | 00 CA 01 10 DB | 2 | 0x162D |  |  |  | 0x00 | CA 01 10 |  |
| 37 38 16 01 20 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | set_vector_or_matrix | 5688.0 | 0120030000000000000000000000000000 | 2 | False | 1 | 00 53 00 53 | 2 | 0x1638 |  |  |  | 0x00 | 53 00 |  |
| 37 0C 1A 00 F4 01 E8 03 DC 05 D0 07 C4 09 B8 0B AC 0D A0 0F 94 | set_vector_or_matrix | 6668.0 | 00f401e803dc05d007c409b80bac0da00f | 2 | False | 1 | 11 53 00 53 | 2 | 0x1A0C |  |  |  | bad_checksum |  |  |
| 37 37 1A 00 0D 03 D1 03 94 04 57 05 DE 06 28 09 35 0C 42 0F 4F | set_vector_or_matrix | 6711.0 | 000d03d10394045705de062809350c420f | 2 | False | 1 | 12 53 00 53 | 2 | 0x1A37 |  |  |  | bad_checksum |  |  |
| 37 3D 1A 00 52 03 46 05 3A 07 C4 09 B8 0B AC 0D A0 0F 94 11 88 | set_vector_or_matrix | 6717.0 | 00520346053a07c409b80bac0da00f9411 | 2 | False | 1 | 13 53 00 53 | 2 | 0x1A3D |  |  |  | bad_checksum |  |  |
| 37 72 1A 00 C2 01 F4 01 26 02 58 02 8A 02 BC 02 EE 02 20 03 52 | set_vector_or_matrix | 6770.0 | 00c201f401260258028a02bc02ee022003 | 2 | False | 1 | 03 53 00 53 | 2 | 0x1A72 |  |  |  | bad_checksum |  |  |
| 37 7F 1A 00 C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 2D C7 | set_vector_or_matrix | 6783.0 | 00c72dc72dc72dc72dc72dc72dc72dc72d | 2 | False | 1 | 2D 53 00 53 | 2 | 0x1A7F |  |  |  | bad_checksum |  |  |
| 37 83 1A 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | set_vector_or_matrix | 6787.0 | 0000000000000000000000000000000000 | 2 | False | 1 | 00 53 00 53 | 2 | 0x1A83 |  |  |  | 0x00 | 53 00 |  |
| 37 BD 1A 00 08 07 08 07 6C 07 D0 07 D0 07 D0 07 34 08 34 08 34 | set_vector_or_matrix | 6845.0 | 00080708076c07d007d007d00734083408 | 2 | False | 1 | 08 53 00 53 | 2 | 0x1ABD |  |  |  | bad_checksum |  |  |
| 37 F1 1A 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 2C | set_vector_or_matrix | 6897.0 | 0000000000000000000000000000000000 | 2 | False | 1 | 01 53 00 53 | 2 | 0x1AF1 |  |  |  | bad_checksum |  |  |
| 37 67 1B 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | set_vector_or_matrix | 7015.0 | 0000000000000000000000000000000000 | 2 | False | 1 | 00 CA 01 10 DB | 2 | 0x1B67 |  |  |  | 0x00 | CA 01 10 |  |
| 37 67 1B 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | set_vector_or_matrix | 7015.0 | 0001000000000000000000000000000000 | 2 | False | 1 | 00 CA 01 10 DB | 2 | 0x1B67 |  |  |  | 0x00 | CA 01 10 |  |
| 37 67 1B 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | set_vector_or_matrix | 7015.0 | 0002000000000000000000000000000000 | 2 | False | 1 | 00 CA 01 10 DB | 2 | 0x1B67 |  |  |  | 0x00 | CA 01 10 |  |
| 37 67 1B 00 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | set_vector_or_matrix | 7015.0 | 0003000000000000000000000000000000 | 2 | False | 1 | 00 CA 01 10 DB | 2 | 0x1B67 |  |  |  | 0x00 | CA 01 10 |  |
| 35 4A 00 A1 07 00 00 27 | set_vector_or_matrix | 74.0 | a1070000 | 2 | True | 1 | 53 00 53 | 2 | 0x004A | TEMPO_MAX_CORRENTE | TSTREAMDATI | TAebVector | ack |  |  |
| 35 51 00 F7 02 E0 02 61 | set_vector_or_matrix | 81.0 | f702e002 | 2 | True | 1 | 53 00 53 | 2 | 0x0051 | TEMP_DIAGNOSI | TSTREAMDATI | TAebVector | ack |  |  |
| 37 35 20 00 00 00 32 30 38 20 66 61 7A 7A 65 6E 64 6F 20 4C 4F | set_vector_or_matrix | 8245.0 | 0000003230382066617a7a656e646f204c | 2 | False | 1 | 47 53 00 53 | 2 | 0x2035 |  |  |  | bad_checksum |  |  |
| 37 5F 20 00 2B 01 90 01 F4 01 57 02 BB 02 20 03 84 03 E8 03 4C | set_vector_or_matrix | 8287.0 | 002b019001f4015702bb0220038403e803 | 2 | False | 1 | 04 53 00 53 | 2 | 0x205F |  |  |  | bad_checksum |  |  |
| 37 60 20 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | set_vector_or_matrix | 8288.0 | 0000000000000000000000000000000000 | 2 | False | 1 | 00 53 00 53 | 2 | 0x2060 |  |  |  | 0x00 | 53 00 |  |
| 37 7B 20 00 E2 04 2C 05 77 05 C3 05 0E 06 59 06 A3 06 EE 06 3A | set_vector_or_matrix | 8315.0 | 00e2042c057705c3050e065906a306ee06 | 2 | False | 1 | 07 53 00 53 | 2 | 0x207B |  |  |  | bad_checksum |  |  |
| 37 7C 20 00 39 0A 15 09 F9 07 E5 06 D7 05 D0 04 CF 03 D4 02 DD | set_vector_or_matrix | 8316.0 | 00390a1509f907e506d705d004cf03d402 | 2 | False | 1 | 01 53 00 53 | 2 | 0x207C |  |  |  | bad_checksum |  |  |
| 37 8B 20 00 E7 E0 D8 CE C3 B7 AA 9C 8E 80 72 65 59 4E 44 3B 33 | set_vector_or_matrix | 8331.0 | 00e7e0d8cec3b7aa9c8e807265594e443b | 2 | False | 1 | 2C 53 00 53 | 2 | 0x208B |  |  |  | bad_checksum |  |  |
| 37 E0 20 00 00 00 8C 00 0E 01 CB 01 6D 02 33 03 1A 04 27 05 72 | set_vector_or_matrix | 8416.0 | 0000008c000e01cb016d0233031a042705 | 2 | False | 1 | 06 53 00 53 | 2 | 0x20E0 |  |  |  | bad_checksum |  |  |
| 37 E3 25 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 | set_vector_or_matrix | 9699.0 | 0000000000000000000000000000000000 | 2 | False | 1 | 00 53 00 53 | 2 | 0x25E3 |  |  |  | 0x00 | 53 00 |  |
| 37 4C 26 01 9A 00 00 01 33 01 66 01 9A 01 CD 01 00 02 33 02 66 | set_vector_or_matrix | 9804.0 | 019a000001330166019a01cd0100023302 | 2 | False | 1 | 02 53 00 53 | 2 | 0x264C |  |  |  | bad_checksum |  |  |
| 48 01 49 | telemetry_or_page | 1.0 |  | 4224 | True | 1172 | 53 22 00 00 38 5B 00 00 00 00 00 00 00 00 26 15 48 08 4D 25 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 08 | 1251 | 0x0001 | REGISTRO_INIT | TSTREAMDATI | TAebNumber | ack | 00 00 38 5B 00 00 00 00 00 00 00 00 26 15 48 08 4D 25 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |  |
| 48 0B 53 | telemetry_or_page | 11.0 |  | 6 | True | 1 | 53 0E 00 00 00 00 00 00 00 00 00 00 00 00 00 03 64 | 6 | 0x000B | RIF_INF_LAMBDA_CALDA | TSTREAMDATI | TAebNumber | ack | 00 00 00 00 00 00 00 00 00 00 00 00 00 03 |  |
| 48 04 4C | telemetry_or_page | 4.0 |  | 17 | True | 17 | 53 08 C2 07 C4 07 BF 07 FF FF B3 | 1 | 0x0004 | TIPO_LAMBDA | TSTREAMDATI | TAebNumber | ack | C2 07 C4 07 BF 07 FF FF |  |
| 48 05 4D | telemetry_or_page | 5.0 |  | 17 | True | 17 | 53 08 A0 11 A4 11 98 11 FF FF 68 | 1 | 0x0005 | RIF_LAMBDA | TSTREAMDATI | TAebNumber | ack | A0 11 A4 11 98 11 FF FF |  |
| 48 08 50 | telemetry_or_page | 8.0 |  | 3462 | True | 1 | CA 01 10 DB | 3462 | 0x0008 | RIF_SUP_LAMBDA_FREDDA | TSTREAMDATI | TAebNumber | ca_status | 01 10 |  |
| 00 | wake |  |  | 16 | True | 2 |  | 8 |  |  |  |  | none |  |  |


## APÊNDICE D — Módulos funcionais e handlers

| Módulo | Eventos | Handlers únicos | Handlers |
| --- | --- | --- | --- |
| TFORMDIAGNOSI | 55 | 24 | ButtonAzzeraErroriClick \| ButtonAzzeraTempiClick \| ButtonResetFFClick \| CheckListBoxFFClickCheck \| CheckSwitchOnDiagnosisClick \| ComboAzioneChange \| ComboAzioneEnter \| ComboAzioneKeyDown \| EditTempBassaMotEnter \| EditTempBassaMotKeyDown \| EditTempBassaMotKeyPress \| FormActivate \| FormClose \| ListDiagnosiClick \| ListDiagnosiKeyDown \| ListDiagnosiKeyPress \| ListDiagnosiSelectItem \| PanelOffClick \| PanelOnClick \| PanelTestOffClick \| PanelTestOnClick \| TimerTempiTimer \| TimerTimer \| TimerUpdateTimer |
| TAUTOCALUI | 49 | 47 | ActionAutoCalRifExecute \| ActionAutoMatchExecute \| ActionChangeColorExecute \| ActionDeleteSelectedPointsExecute \| ActionExportChartDataExecute \| ActionExportChartPointExecute \| ActionExportKChartExecute \| ActionExportToKExecute \| ActionFinishAutocalExecute \| ActionGoToMinCalibrationExecute \| ActionResetAllExecute \| ActionResetGasExecute \| ActionResetKFactorExecute \| ActionResetPetrolExecute \| BtnDeleteRandomPointClick \| BtnDumpClick \| BtnDumpEEClick \| BtnFinishAutomatchClick \| BtnMenuClick \| BtnMenuPanelLeftClick \| BtnShowBandClick \| ChartDataAfterDraw \| ChartDataClickAxis \| ChartDataClickSeries \| ChartDataDblClick \| ChartDataKeyDown \| ChartDataKeyUp \| ChartDataMouseMove \| ChartDataMouseUp \| ChartKLineClickSeries \| ChartKLineDblClick \| ChartKLineDragOver \| ChartKLineEndDrag \| ChartKLineKeyDown \| ChartKLineKeyUp \| ChartKLineMouseDown \| ChartKLineMouseMove \| ChartPointMouseMove \| CheckAutoCalEnableBeforeSetData \| DbgBtnRandomClick \| KLineGetMarkText \| MenuChartDataPopup \| SettingsImgClick \| SettingsImgMouseEnter \| SettingsImgMouseLeave \| TestAreasClick \| TimerMessageSwitchToGasTimer |
| TFORMMAIN | 49 | 35 | ActionAggiornaExecute \| ActionApriConfExecute \| ActionApriExecute \| ActionArchivioExecute \| ActionAzzeraIdExecute \| ActionBloccoNoteExecute \| ActionConfExecute \| ActionConnettiExecute \| ActionCorrTaraExecute \| ActionDiagnosiExecute \| ActionDisconnettiExecute \| ActionEsciExecute \| ActionFileHcfExecute \| ActionProgrammaExecute \| ActionResetCentralinaExecute \| ActionResetDaPcExecute \| ActionSalvaConfExecute \| ActionSalvaExecute \| ActionSalvaMappaExecute \| ActionTaraExecute \| ActionUpdateExecute \| ActionVisualizzaExecute \| FormClose \| FormCloseQuery \| FormPaint \| FormResize \| FormShow \| ImageBeeClick \| ImageLandiConnectClick \| ImageServiceClick \| MenuAboutClick \| Plot1Click \| StatusBarMainDrawPanel \| TimerExpiredTimer \| TimerUpdateTimer |
| TFORMGRAFICOSCOPE | 39 | 31 | ActionAddMarkerExecute \| ActionNextMarkerExecute \| ActionPreviousMarkerExecute \| ActionRimuoviCursoreExecute \| ChartDrtClickAxis \| ChartDrtMouseMove \| ChartDrtMouseUp \| ChartDrtZoom \| CheckAutoMarkerClick \| EditMaxRangeEnter \| EditMaxRangeExit \| EditRangeKeyPress \| EditResolutionKeyPress \| FormClose \| FormCloseQuery \| FormKeyPress \| FormMouseWheelDown \| FormMouseWheelUp \| FormResize \| FormShow \| MenuRimuoviMarkerClick \| TimerTimer \| btnAutoRangeClick \| btnExportImageClick \| btnLegendClick \| btnLoadClick \| btnRestoreZoomClick \| btnRunClick \| btnSaveClick \| btnZoomInClick \| btnZoomOutClick |
| TAEBBEEFORMLIGHT | 33 | 28 | ButtonAbortClick \| ButtonChangePinClick \| ButtonConnectMcuClick \| ButtonDisconnectMcuClick \| ButtonProgramDongleClick \| ButtonProgramMcuClick \| ButtonReadPinClick \| ButtonRemovePinClick \| ButtonScanClick \| ButtonScanEnergyClick \| ButtonSfogliaDongleClick \| ButtonSfogliaMcuClick \| ComboCanaleChange \| ComboPotenzaDongleChange \| ComboPotenzaMcuChange \| DongleExit \| EditIndirizzoDongleKeyPress \| EditIndirizzoMcuKeyPress \| EditNomeDongleKeyPress \| EditNomeMcuKeyPress \| EditPinKeyPress \| FormClose \| FormCloseQuery \| FormKeyPress \| ListDeviceDblClick \| McuExit \| TabScansioneShow \| TimerUpdateTimer |
| TFORMLANDICONNECT | 22 | 11 | ButtonResetClick \| CheckCambioAutomaticoClick \| CheckEnableGearClick \| CheckEnableLandiConnectClick \| DrawGridInjrTOfsTblDblClick \| DrawGridInjrTOfsTblDrawCell \| DrawGridInjrTOfsTblKeyPress \| EditEnter \| EditExit \| FormKeyPress \| TimerUpdateTimer |
| TSTRATEGIATEMPIMORTIUI | 20 | 2 | UpDownGasAClick \| UpDownPetrolAClick |
| TFORMSERVICE | 16 | 14 | ButtonAzzeraNumeroTagliandiEffettuatiClick \| ButtonExitClick \| ButtonNewPinClick \| ButtonOldPinClick \| ButtonResetPinClick \| CheckDisableGasClick \| EditInsPinChange \| EditPinKeyPress \| EditStandardEnter \| EditStandardExit \| EditStandardKeyPress \| FormClose \| FormKeyPress \| MemoDataKeyPress |
| TAUTOCALCOLORSETTINGS | 16 | 4 | ChartDataAfterDraw \| Image1Click \| OKClick \| _AcqusitionAreas0Click |
| TFORMSWITCH | 11 | 9 | ButtonExitClick \| ComboBuzzerEnter \| ComboBuzzerKeyPress \| EditSwitchEnter \| EditSwitchKeyPress \| FormClose \| FormKeyPress \| TrackBarLedChange \| TrackBarLedEnter |
| TFORMFILE | 11 | 11 | ButtonAggiornaClick \| ButtonOkClick \| EditNameKeyDown \| FormActivate \| FormClose \| TreeViewFileChange \| TreeViewFileClick \| TreeViewFileCompare \| TreeViewFileDblClick \| TreeViewFileDragDrop \| TreeViewFileKeyDown |
| TABOUTBOX | 9 | 9 | AboutImageDblClick \| ButtonDeleteLicenseClick \| ButtonLoadLicenseClick \| ButtonRequestClick \| ButtonSendByMailClick \| EditRegCodeKeyPress \| EditRegCodeKeyUp \| FormKeyPress \| OkButtonClick |
| TAUTOCALSETTINGS | 6 | 6 | BitBtn1Click \| BtnChangeColorClick \| CalibrationValWriteItem \| FormClose \| FormShow \| RefreshTimeChange |
| TFORMCALIBRA | 6 | 5 | ButtonEsciClick \| ButtonProseguiClick \| FormClose \| FormKeyPress \| TimerBlinkTimer |
| TFORMCORRCALIBRA | 6 | 6 | ActionDecrementaZonaExecute \| ActionEsciExecute \| ActionIncrementaZonaExecute \| DrawGridKDrawCell \| FormClose \| TimerBlinkTimer |
| TFORMGRAFICODRT | 5 | 5 | ChartDrtClickSeries \| MenuAnnullaZoomClick \| MenuEsciClick \| MenuStampaClick \| MenuTracceClick |
| TFORMCENTRICELLEK | 4 | 4 | ButtonAnnullaExit \| ButtonOkClick \| ButtonOkExit \| FormShow |
| TAUTOCALDM | 4 | 2 | AUTO_CAL_ENABLEGetData \| VECT_AUTOCAL_U8_2GetData |
| TSTRATEGIAPANDAUI | 3 | 3 | chk_SP_EN_STRATEGIA_EMU_SENS_PRESS_CLIMAClick \| chk_SP_EN_STRATEGIA_MINIMOClick \| chk_SP_EN_STRATEGIA_RIC_CLIMAClick |
| TFORMCENTRICELLE | 3 | 3 | ButtonAnnullaExit \| ButtonOkClick \| FormShow |
| TFORMVISUALIZZA | 3 | 3 | ButtonCommutatoreClick \| FormClose \| Timer1Timer |
| TFORMMODIFICAMAPPA | 2 | 2 | EditDataKeyPress \| FormClose |
| TFORMMODMAPPA | 2 | 2 | EditValoreKeyPress \| FormClose |
| TFORMAGGKEY | 1 | 1 | FormShow |
| TFORMRIFAUTOCAL | 1 | 1 | ButtonOkClick |
| TFORMSCARICA | 1 | 1 | ButtonCambiaClick |
| TFORMRIFERIMENTI | 1 | 1 | FormCloseQuery |
| TSTREAMDATI | 1 | 1 | TimerIOTimer |


## APÊNDICE E — Formulário/telas encontradas

| resource | root_class | root_name | size | parsed |
| --- | --- | --- | --- | --- |
| TABOUTBOX | TAboutBox | AboutBox | 4952 | 4952 |
| TAEBBEEFORMLIGHT | TAebBeeFormLight | AebBeeFormLight | 32758 | 32758 |
| TAUTOCALCOLORSETTINGS | TAutocalColorSettings | AutocalColorSettings | 278351 | 278351 |
| TAUTOCALDM | TAutoCalDM | AutoCalDM | 14428 | 14428 |
| TAUTOCALDM_EE | TAutoCalDM_EE | AutoCalDM_EE | 6179 | 6179 |
| TAUTOCALSETTINGS | TAutoCalSettings | AutoCalSettings | 59366 | 59366 |
| TAUTOCALUI | TAutoCalUI | AutoCalUI | 184604 | 184604 |
| TFFDATAMODULESINGLEARRAY | TFFDataModuleSingleArray | FFDataModuleSingleArray | 1690 | 1690 |
| TFORMAGGKEY | TFormAggKey | FormAggKey | 2072 | 2072 |
| TFORMATTESA | TFormAttesa | FormAttesa | 988 | 988 |
| TFORMCALIBRA | TFormCalibra | FormCalibra | 13159 | 13159 |
| TFORMCENTRICELLE | TFormCentriCelle | FormCentriCelle | 7478 | 7478 |
| TFORMCENTRICELLEK | TFormCentriCelleK | FormCentriCelleK | 7616 | 7616 |
| TFORMCORRCALIBRA | TFormCorrCalibra | FormCorrCalibra | 3607 | 3607 |
| TFORMDIAGNOSI | TFormDiagnosi | FormDiagnosi | 38390 | 38390 |
| TFORMFILE | TFormFile | FormFile | 63700 | 63700 |
| TFORMGESTIONETRACCE | TFormGestioneTracce | FormGestioneTracce | 804 | 804 |
| TFORMGRAFICODRT | TFormGraficoDrt | FormGraficoDrt | 4896 | 4896 |
| TFORMGRAFICOSCOPE | TFormGraficoScope | FormGraficoScope | 227164 | 227164 |
| TFORMHELPSCOPE | TFormHelpScope | FormHelpScope | 81025 | 81025 |
| TFORMLANDICONNECT | TFormLandiConnect | FormLandiConnect | 690735 | 690735 |
| TFORMMAIN | TFormMain | FormMain | 88434 | 88434 |
| TFORMMAINBASE | TFormMainBase | FormMainBase | 301 | 301 |
| TFORMMESSAGGIO | TFormMessaggio | FormMessaggio | 584 | 584 |
| TFORMMODIFICAMAPPA | TFormModificaMappa | FormModificaMappa | 806 | 806 |
| TFORMMODMAPPA | TFormModMappa | FormModMappa | 1052 | 1052 |
| TFORMPDF | TFormPdf | FormPdf | 460 | 460 |
| TFORMRIFAUTOCAL | TFormRifAutocal | FormRifAutocal | 11172 | 11172 |
| TFORMRIFERIMENTI | TFormRiferimenti | FormRiferimenti | 753 | 753 |
| TFORMSCARICA | TFormScarica | FormScarica | 1710 | 1710 |
| TFORMSERVICE | TFormService | FormService | 7423 | 7423 |
| TFORMSPLASH | TFormSplash | FormSplash | 434 | 434 |
| TFORMSTAMPA | TFormStampa | FormStampa | 392 | 392 |
| TFORMSWITCH | TFormSwitch | FormSwitch | 2338 | 2338 |
| TFORMVISUALIZZA | TFormVisualizza | FormVisualizza | 84613 | 84613 |
| TSTRATEGIAPANDADM | TStrategiaPandaDM | StrategiaPandaDM | 7696 | 7696 |
| TSTRATEGIAPANDADM_EE | TStrategiaPandaDM_EE | StrategiaPandaDM_EE | 82 | 82 |
| TSTRATEGIAPANDAUI | TStrategiaPandaUI | StrategiaPandaUI | 17181 | 17181 |
| TSTRATEGIATEMPIMORTIDM | TStrategiaTempiMortiDM | StrategiaTempiMortiDM | 890 | 890 |
| TSTRATEGIATEMPIMORTIDM_EE | TStrategiaTempiMortiDM_EE | StrategiaTempiMortiDM_EE | 92 | 92 |
| TSTRATEGIATEMPIMORTIUI | TStrategiaTempiMortiUI | StrategiaTempiMortiUI | 20601 | 20601 |
| TSTREAMDATI | TStreamDati | StreamDati | 109011 | 109011 |


## APÊNDICE F — Definição de pronto para uma réplica industrial


Uma implementação só pode ser considerada equivalente em nível industrial quando:

- conecta e identifica a ECU de forma repetível;
- reproduz eco, checksum, ACK/NAK/CA;
- passa replay integral das capturas;
- decodifica telemetria com perfil versionado;
- lê todos os parâmetros suportados respeitando tamanho dinâmico;
- lê e reconstrói K;
- escreve célula/linha com readback e rollback em bancada;
- implementa AutoMatch com dimensões dinâmicas e estados transparentes;
- mantém todas as funções experimentais bloqueadas por confiança/perfil;
- registra auditoria completa;
- sobrevive a cabo removido, ignição off/on, ruído e banco corrompido;
- nunca transforma hipótese em comando silencioso.


---
Documento gerado com 11,378 linhas. SHA-256 preliminar: `82a96e3d142694f0b83f4642d9a2d3f71c079909e2d5e5d2f202cfb3f67bb29b`.

