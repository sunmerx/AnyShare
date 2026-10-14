# -*- coding: utf-8 -*-
"""Pairing-copy update: paired devices auto-accept (levelTemp label + done)."""
import json, io, os

DONE = {
 'en': "Paired with {name}. Transfers from paired devices are accepted automatically — set limits below if needed.",
 'zh-CN': "已与 {name} 配对。之后来自已配对设备的传输将自动接收,如需限制可在下方设置。",
 'fr': "Associé à {name}. Les transferts des appareils associés sont acceptés automatiquement — définissez des limites ci-dessous si besoin.",
 'de': "Mit {name} gekoppelt. Übertragungen von gekoppelten Geräten werden automatisch angenommen — bei Bedarf unten Grenzen setzen.",
 'ja': "{name} とペアリングしました。ペアリング済みデバイスからの転送は自動的に受け入れます。制限は下で設定できます。",
 'ko': "{name}와(과) 페어링되었습니다. 페어링된 기기의 전송은 자동으로 수신됩니다. 필요 시 아래에서 한도를 설정하세요.",
 'ru': "Сопряжено с {name}. Передачи от сопряжённых устройств принимаются автоматически — при необходимости задайте лимиты ниже.",
 'it': "Associato a {name}. I trasferimenti dai dispositivi associati vengono accettati automaticamente — imposta eventuali limiti sotto.",
 'pl': "Sparowano z {name}. Transfery z sparowanych urządzeń są przyjmowane automatycznie — w razie potrzeby ustaw limity poniżej.",
 'nl': "Gekoppeld met {name}. Overdrachten van gekoppelde apparaten worden automatisch geaccepteerd — stel zonodig limieten in onderaan.",
 'tr': "{name} ile eşleştirildi. Eşleştirilmiş cihazlardan gelen aktarımlar otomatik kabul edilir — gerekirse aşağıdan sınır koyun.",
 'vi': "Đã ghép cặp với {name}. Các tệp từ thiết bị đã ghép cặp sẽ được tự động nhận — đặt giới hạn bên dưới nếu cần.",
 'uk': "З'єднано з {name}. Передачі від з'єднаних пристроїв приймаються автоматично — за потреби задайте ліміти нижче.",
 'id': "Terpasang dengan {name}. Transfer dari perangkat yang terpasang diterima otomatis — atur batas di bawah bila perlu.",
}
LEVEL_TEMP = {
 'en': "Temporary (auto-accept)",
 'zh-CN': "临时传输(自动接收)",
 'fr': "Temporaire (acceptation automatique)",
 'de': "Temporär (automatisch annehmen)",
 'ja': "一時的(自動的に受け入れる)",
 'ko': "임시(자동 수락)",
 'ru': "Временный (принимать автоматически)",
 'it': "Temporaneo (accettazione automatica)",
 'pl': "Tymczasowe (automatyczne przyjmowanie)",
 'nl': "Tijdelijk (automatisch accepteren)",
 'tr': "Geçici (otomatik kabul)",
 'vi': "Tạm thời (tự động nhận)",
 'uk': "Тимчасовий (приймати автоматично)",
 'id': "Sementara (terima otomatis)",
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for loc in DONE:
    path = os.path.join(ROOT, 'app', 'assets', 'i18n', loc + '.json')
    try:
        d = json.load(io.open(path, encoding='utf-8'))
    except FileNotFoundError:
        print(loc, ': missing, skip')
        continue
    d.setdefault('deviceDetailsPage', {}).setdefault('pairing', {})
    d['deviceDetailsPage']['pairing']['done'] = DONE[loc]
    d['deviceDetailsPage']['trust']['levelTemp'] = LEVEL_TEMP[loc]
    io.open(path, 'w', encoding='utf-8', newline='\n').write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
    print(loc, 'patched')
