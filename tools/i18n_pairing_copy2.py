# -*- coding: utf-8 -*-
"""Trust semantics copy (2026-10-14 revised): receiver taps confirm for
temp/limited; only full trust is tap-free. Pairing done message reflects it."""
import json, io, os

DONE = {
 'en': "Paired with {name}. The receiver confirms each transfer (full trust accepts automatically) — set limits below if needed.",
 'zh-CN': "已与 {name} 配对。传输由接收方点击确认(完全信任则自动接收),如需限制可在下方设置。",
 'fr': "Associé à {name}. Le récepteur confirme chaque transfert (la confiance totale accepte automatiquement) — définissez des limites ci-dessous si besoin.",
 'de': "Mit {name} gekoppelt. Der Empfänger bestätigt jede Übertragung (volles Vertrauen nimmt automatisch an) — bei Bedarf unten Grenzen setzen.",
 'ja': "{name} とペアリングしました。転送は受信側が確認します(完全信頼は自動)。制限は下で設定できます。",
 'ko': "{name}와(과) 페어링되었습니다. 전송은 수신 측이 확인합니다(완전 신뢰는 자동 수락). 필요 시 아래에서 한도를 설정하세요.",
 'ru': "Сопряжено с {name}. Получатель подтверждает каждую передачу (полное доверие — автоматически) — при необходимости задайте лимиты ниже.",
 'it': "Associato a {name}. Il ricevente conferma ogni trasferimento (fiducia piena: automatico) — imposta eventuali limiti sotto.",
 'pl': "Sparowano z {name}. Odbiorca potwierdza każdy transfer (pełne zaufanie: automatycznie) — w razie potrzeby ustaw limity poniżej.",
 'nl': "Gekoppeld met {name}. De ontvanger bevestigt elke overdracht (volledig vertrouwen: automatisch) — stel zonodig limieten in onderaan.",
 'tr': "{name} ile eşleştirildi. Aktarımları alıcı onaylar (tam güven: otomatik) — gerekirse aşağıdan sınır koyun.",
 'vi': "Đã ghép cặp với {name}. Bên nhận xác nhận từng tệp (tin cậy hoàn toàn: tự động) — đặt giới hạn bên dưới nếu cần.",
 'uk': "З'єднано з {name}. Отримувач підтверджує кожну передачу (повна довіра: автоматично) — за потреби задайте ліміти нижче.",
 'id': "Terpasang dengan {name}. Penerima mengonfirmasi setiap transfer (kepercayaan penuh: otomatis) — atur batas di bawah bila perlu.",
}
LEVEL_TEMP = {
 'en': "Temporary (receiver confirms)",
 'zh-CN': "临时传输(接收方确认)",
 'fr': "Temporaire (le récepteur confirme)",
 'de': "Temporär (Empfänger bestätigt)",
 'ja': "一時的(受信側が確認)",
 'ko': "임시(수신 측 확인)",
 'ru': "Временный (подтверждает получатель)",
 'it': "Temporaneo (conferma del ricevente)",
 'pl': "Tymczasowe (potwierdza odbiorca)",
 'nl': "Tijdelijk (ontvanger bevestigt)",
 'tr': "Geçici (alıcı onaylar)",
 'vi': "Tạm thời (bên nhận xác nhận)",
 'uk': "Тимчасовий (підтверджує отримувач)",
 'id': "Sementara (penerima mengonfirmasi)",
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
