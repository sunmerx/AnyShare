# -*- coding: utf-8 -*-
"""sendTab trust-hint strings for /trust/query pre-send hints."""
import json, io, os

HINTS = {
 'en': {"trustHintAutoAccept":"{alias} will accept your transfer automatically","trustHintLimited":"{alias} has limits set (max file: {max}, quota: {quota}) — exceeding them will be declined","trustHintBlocked":"{alias} has blocked you — the transfer will be declined"},
 'zh-CN': {"trustHintAutoAccept":"{alias} 将自动接收你的传输","trustHintLimited":"{alias} 设置了限额(单文件 {max},容量 {quota}),超出将被自动拒绝","trustHintBlocked":"{alias} 已拉黑你,发送将被拒绝"},
 'fr': {"trustHintAutoAccept":"{alias} acceptera automatiquement votre transfert","trustHintLimited":"{alias} a des limites (fichier max : {max}, quota : {quota}) — les dépassements seront refusés","trustHintBlocked":"{alias} vous a bloqué — le transfert sera refusé"},
 'de': {"trustHintAutoAccept":"{alias} nimmt deine Übertragung automatisch an","trustHintLimited":"{alias} hat Grenzen gesetzt (max. Datei: {max}, Kontingent: {quota}) — Überschreitungen werden abgelehnt","trustHintBlocked":"{alias} hat dich blockiert — die Übertragung wird abgelehnt"},
 'ja': {"trustHintAutoAccept":"{alias} は転送を自動的に受け入れます","trustHintLimited":"{alias} は制限を設定しています(最大ファイル {max}、容量 {quota})。超過すると拒否されます","trustHintBlocked":"{alias} はあなたをブロックしています。転送は拒否されます"},
 'ko': {"trustHintAutoAccept":"{alias}이(가) 전송을 자동으로 수락합니다","trustHintLimited":"{alias}이(가) 한도를 설정했습니다(최대 파일 {max}, 용량 {quota}). 초과 시 거부됩니다","trustHintBlocked":"{alias}이(가) 당신을 차단했습니다. 전송이 거부됩니다"},
 'ru': {"trustHintAutoAccept":"{alias} примет вашу передачу автоматически","trustHintLimited":"У {alias} заданы лимиты (макс. файл: {max}, квота: {quota}) — превышение будет отклонено","trustHintBlocked":"{alias} заблокировал вас — передача будет отклонена"},
 'it': {"trustHintAutoAccept":"{alias} accetterà automaticamente il tuo trasferimento","trustHintLimited":"{alias} ha impostato limiti (file max: {max}, quota: {quota}) — gli eccedenze saranno rifiutate","trustHintBlocked":"{alias} ti ha bloccato — il trasferimento sarà rifiutato"},
 'pl': {"trustHintAutoAccept":"{alias} przyjmie twój transfer automatycznie","trustHintLimited":"{alias} ustawił limity (maks. plik: {max}, limit: {quota}) — przekroczenia zostaną odrzucone","trustHintBlocked":"{alias} zablokował cię — transfer zostanie odrzucony"},
 'nl': {"trustHintAutoAccept":"{alias} accepteert je overdracht automatisch","trustHintLimited":"{alias} heeft limieten ingesteld (max. bestand: {max}, quotum: {quota}) — overschrijding wordt geweigerd","trustHintBlocked":"{alias} heeft je geblokkeerd — de overdracht wordt geweigerd"},
 'tr': {"trustHintAutoAccept":"{alias} aktarımınızı otomatik kabul edecek","trustHintLimited":"{alias} sınırlar ayarladı (maks. dosya: {max}, kota: {quota}) — aşımı reddedilir","trustHintBlocked":"{alias} sizi engelledi — aktarım reddedilecek"},
 'vi': {"trustHintAutoAccept":"{alias} sẽ tự động nhận tệp của bạn","trustHintLimited":"{alias} đã đặt giới hạn (tệp tối đa: {max}, hạn mức: {quota}) — vượt sẽ bị từ chối","trustHintBlocked":"{alias} đã chặn bạn — tệp sẽ bị từ chối"},
 'uk': {"trustHintAutoAccept":"{alias} автоматично прийме вашу передачу","trustHintLimited":"{alias} встановив ліміти (макс. файл: {max}, квота: {quota}) — перевищення буде відхилено","trustHintBlocked":"{alias} заблокував вас — передачу буде відхилено"},
 'id': {"trustHintAutoAccept":"{alias} akan menerima transfer Anda secara otomatis","trustHintLimited":"{alias} menetapkan batas (file maks.: {max}, kuota: {quota}) — kelebihan akan ditolak","trustHintBlocked":"{alias} memblokir Anda — transfer akan ditolak"},
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for loc, h in HINTS.items():
    path = os.path.join(ROOT, 'app', 'assets', 'i18n', loc + '.json')
    try:
        d = json.load(io.open(path, encoding='utf-8'))
    except FileNotFoundError:
        print(loc, ': missing, skip')
        continue
    d.setdefault('sendTab', {}).update(h)
    io.open(path, 'w', encoding='utf-8', newline='\n').write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
    print(loc, 'patched')
