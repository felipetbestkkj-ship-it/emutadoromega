import argparse, datetime, serial, time

ap = argparse.ArgumentParser()
ap.add_argument('--port', default=r'\\.\CNCB0')
ap.add_argument('--log', default='build/captures/ecu-cnc.log')
args = ap.parse_args()

def log(msg):
    with open(args.log, 'a', encoding='utf-8') as f:
        f.write(f'{datetime.datetime.now().isoformat(timespec="milliseconds")} {msg}\n')

ser = serial.Serial(args.port, 115200, timeout=0.2)
log(f'open port={args.port}')
try:
    while True:
        data = ser.read(256)
        if not data:
            continue
        hx = data.hex(' ')
        log(f'rx length={len(data)} hex={hx}')
        ser.write(data)
        ser.write(b'\x53')
        ser.flush()
        log(f'tx echo={hx} ack=53')
finally:
    ser.close()
    log('close')
