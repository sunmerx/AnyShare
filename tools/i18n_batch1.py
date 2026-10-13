# -*- coding: utf-8 -*-
"""i18n batch 1 (es/fr/de/ja/ko/ru) for trust + pairing + send history."""
import json, io, os

TR = {
 'es': {
  "trust": {"title":"Confianza","level":"Nivel de confianza","levelTemp":"Temporal (preguntar siempre)","levelLimited":"Confianza con límites","levelFull":"Totalmente confiable (sin límites)","blocked":"Bloqueado","blockedHint":"Rechazar todas las transferencias de este dispositivo sin preguntar","maxFileSize":"Tamaño máx. de archivo","maxFileSizeUnlimited":"Sin límite","quota":"Cuota de recepción","quotaNone":"Sin límite","quotaAbsolute":"Tamaño absoluto","quotaPercent":"Porcentaje del disco","quotaUsed":"Usado: {used}","quotaLimit":"Límite: {limit}","resetUsage":"Reiniciar uso","resetUsageConfirm":"¿Reiniciar el uso de recepción registrado de este dispositivo?","usage":"Uso","percentHint":"Porcentaje del disco de destino"},
  "pairing": {"start":"Vincular (AnyShare)","notSupported":"El dispositivo no responde como AnyShare. Aún puedes marcarlo como favorito para la aceptación automática.","probing":"Contactando el dispositivo…","codeTitle":"Verifica que ambas pantallas muestren el mismo código","waitingPeer":"Esperando al otro dispositivo…","match":"Los códigos coinciden","mismatch":"Los códigos difieren","done":"Vinculado con {name}. Nivel de confianza: temporal (cámbialo abajo).","errorNotAnyShare":"El dispositivo no es una app AnyShare.","errorUnreachable":"No se pudo conectar con el dispositivo.","errorBusy":"El dispositivo está ocupado con otro emparejamiento.","errorRejected":"El emparejamiento fue rechazado.","errorProtocol":"Respuesta de emparejamiento inesperada."},
  "incoming": {"title":"Solicitud de vinculación","body":"{name} quiere vincularse. Verifica que ambas pantallas muestren el mismo código:","match":"Los códigos coinciden","mismatch":"Los códigos difieren"},
  "send": {"title":"Archivos enviados","empty":"Aún no hay archivos enviados"},
 },
 'fr': {
  "trust": {"title":"Confiance","level":"Niveau de confiance","levelTemp":"Temporaire (demander à chaque fois)","levelLimited":"Confiance limitée","levelFull":"Confiance totale (sans limite)","blocked":"Bloqué","blockedHint":"Rejeter tous les transferts de cet appareil sans demander","maxFileSize":"Taille max. du fichier","maxFileSizeUnlimited":"Illimité","quota":"Quota de réception","quotaNone":"Illimité","quotaAbsolute":"Taille absolue","quotaPercent":"Pourcentage du disque","quotaUsed":"Utilisé : {used}","quotaLimit":"Limite : {limit}","resetUsage":"Réinitialiser l'utilisation","resetUsageConfirm":"Réinitialiser l'utilisation enregistrée pour cet appareil ?","usage":"Utilisation","percentHint":"Pourcentage du disque de destination"},
  "pairing": {"start":"Associer (AnyShare)","notSupported":"Cet appareil ne répond pas comme AnyShare. Vous pouvez toujours le mettre en favori pour l'acceptation automatique.","probing":"Contact de l'appareil…","codeTitle":"Vérifiez que les deux écrans affichent le même code","waitingPeer":"En attente de l'autre appareil…","match":"Les codes correspondent","mismatch":"Les codes diffèrent","done":"Associé à {name}. Niveau de confiance : temporaire (modifiable ci-dessous).","errorNotAnyShare":"L'appareil n'est pas une application AnyShare.","errorUnreachable":"Impossible de joindre l'appareil.","errorBusy":"L'appareil est occupé avec une autre association.","errorRejected":"L'association a été refusée.","errorProtocol":"Réponse d'association inattendue."},
  "incoming": {"title":"Demande d'association","body":"{name} souhaite s'associer. Vérifiez que les deux écrans affichent le même code :","match":"Les codes correspondent","mismatch":"Les codes diffèrent"},
  "send": {"title":"Fichiers envoyés","empty":"Aucun fichier envoyé"},
 },
 'de': {
  "trust": {"title":"Vertrauen","level":"Vertrauensstufe","levelTemp":"Temporär (jedes Mal fragen)","levelLimited":"Begrenzt vertraut","levelFull":"Voll vertraut (ohne Grenzen)","blocked":"Blockiert","blockedHint":"Alle Übertragungen dieses Geräts ohne Nachfrage ablehnen","maxFileSize":"Max. Dateigröße","maxFileSizeUnlimited":"Unbegrenzt","quota":"Empfangskontingent","quotaNone":"Unbegrenzt","quotaAbsolute":"Absolute Größe","quotaPercent":"Prozent der Festplatte","quotaUsed":"Benutzt: {used}","quotaLimit":"Grenze: {limit}","resetUsage":"Nutzung zurücksetzen","resetUsageConfirm":"Die aufgezeichnete Empfangsnutzung dieses Geräts zurücksetzen?","usage":"Nutzung","percentHint":"Prozent des Ziellaufwerks"},
  "pairing": {"start":"Koppeln (AnyShare)","notSupported":"Dieses Gerät antwortet nicht als AnyShare. Du kannst es trotzdem als Favorit für Auto-Annahme hinzufügen.","probing":"Gerät wird kontaktiert…","codeTitle":"Prüfe, dass beide Bildschirme denselben Code zeigen","waitingPeer":"Warte auf das andere Gerät…","match":"Codes stimmen überein","mismatch":"Codes weichen ab","done":"Mit {name} gekoppelt. Vertrauensstufe: temporär (unten änderbar).","errorNotAnyShare":"Das Gerät ist keine AnyShare-App.","errorUnreachable":"Gerät nicht erreichbar.","errorBusy":"Das Gerät ist mit einer anderen Kopplung beschäftigt.","errorRejected":"Kopplung wurde abgelehnt.","errorProtocol":"Unerwartete Kopplungsantwort."},
  "incoming": {"title":"Kopplungsanfrage","body":"{name} möchte sich koppeln. Prüfe, dass beide Bildschirme denselben Code zeigen:","match":"Codes stimmen überein","mismatch":"Codes weichen ab"},
  "send": {"title":"Gesendete Dateien","empty":"Noch keine gesendeten Dateien"},
 },
 'ja': {
  "trust": {"title":"信頼","level":"信頼レベル","levelTemp":"一時的(毎回確認)","levelLimited":"制限付き信頼","levelFull":"完全信頼(無制限)","blocked":"ブロック","blockedHint":"このデバイスからの転送を確認なしで拒否","maxFileSize":"最大ファイルサイズ","maxFileSizeUnlimited":"無制限","quota":"受信クォータ","quotaNone":"無制限","quotaAbsolute":"絶対容量","quotaPercent":"ディスク割合","quotaUsed":"使用済み: {used}","quotaLimit":"上限: {limit}","resetUsage":"使用量をリセット","resetUsageConfirm":"このデバイスの記録された受信使用量をリセットしますか?","usage":"使用量","percentHint":"保存先ディスクの割合"},
  "pairing": {"start":"ペアリング(AnyShare)","notSupported":"相手は AnyShare として応答しません。自動受信用にお気に入りへ追加できます。","probing":"デバイスに接続中…","codeTitle":"両方の画面に同じコードが表示されているか確認してください","waitingPeer":"相手の操作を待っています…","match":"コードが一致","mismatch":"コードが一致しません","done":"{name} とペアリングしました。信頼レベル:一時的(下で変更できます)。","errorNotAnyShare":"相手は AnyShare アプリではありません。","errorUnreachable":"デバイスに接続できません。","errorBusy":"相手は別のペアリング処理中です。","errorRejected":"ペアリングが拒否されました。","errorProtocol":"予期しないペアリング応答。"},
  "incoming": {"title":"ペアリング要求","body":"{name} がペアリングを要求しています。両方の画面に同じコードが表示されているか確認してください:","match":"コードが一致","mismatch":"コードが一致しません"},
  "send": {"title":"送信済みファイル","empty":"送信済みファイルはありません"},
 },
 'ko': {
  "trust": {"title":"신뢰","level":"신뢰 수준","levelTemp":"임시(매번 확인)","levelLimited":"제한적 신뢰","levelFull":"완전 신뢰(제한 없음)","blocked":"차단","blockedHint":"이 기기의 모든 전송을 묻지 않고 거부","maxFileSize":"최대 파일 크기","maxFileSizeUnlimited":"제한 없음","quota":"수신 할당량","quotaNone":"제한 없음","quotaAbsolute":"절대 용량","quotaPercent":"디스크 비율","quotaUsed":"사용량: {used}","quotaLimit":"한도: {limit}","resetUsage":"사용량 초기화","resetUsageConfirm":"이 기기의 기록된 수신 사용량을 초기화할까요?","usage":"사용량","percentHint":"대상 디스크의 비율"},
  "pairing": {"start":"페어링(AnyShare)","notSupported":"이 기기는 AnyShare로 응답하지 않습니다. 자동 수신용으로 즐겨찾기에 추가할 수는 있습니다.","probing":"기기에 연결 중…","codeTitle":"두 화면에 같은 코드가 표시되는지 확인하세요","waitingPeer":"상대 기기를 기다리는 중…","match":"코드 일치","mismatch":"코드 불일치","done":"{name}와(과) 페어링되었습니다. 신뢰 수준: 임시(아래에서 변경 가능).","errorNotAnyShare":"상대 기기는 AnyShare 앱이 아닙니다.","errorUnreachable":"기기에 연결할 수 없습니다.","errorBusy":"상대 기기가 다른 페어링 중입니다.","errorRejected":"페어링이 거부되었습니다.","errorProtocol":"예상치 못한 페어링 응답."},
  "incoming": {"title":"페어링 요청","body":"{name}이(가) 페어링을 요청합니다. 두 화면에 같은 코드가 표시되는지 확인하세요:","match":"코드 일치","mismatch":"코드 불일치"},
  "send": {"title":"보낸 파일","empty":"보낸 파일이 없습니다"},
 },
 'ru': {
  "trust": {"title":"Доверие","level":"Уровень доверия","levelTemp":"Временный (спрашивать каждый раз)","levelLimited":"Доверие с ограничениями","levelFull":"Полное доверие (без ограничений)","blocked":"Заблокировано","blockedHint":"Отклонять все передачи этого устройства без запроса","maxFileSize":"Макс. размер файла","maxFileSizeUnlimited":"Без ограничений","quota":"Квота приёма","quotaNone":"Без ограничений","quotaAbsolute":"Абсолютный размер","quotaPercent":"Процент диска","quotaUsed":"Использовано: {used}","quotaLimit":"Лимит: {limit}","resetUsage":"Сбросить учёт","resetUsageConfirm":"Сбросить учёт объёма приёма для этого устройства?","usage":"Учёт","percentHint":"Процент целевого диска"},
  "pairing": {"start":"Сопряжение (AnyShare)","notSupported":"Устройство не отвечает как AnyShare. Его всё же можно добавить в избранное для автоприёма.","probing":"Подключение к устройству…","codeTitle":"Убедитесь, что на обоих экранах один и тот же код","waitingPeer":"Ожидание второго устройства…","match":"Коды совпадают","mismatch":"Коды различаются","done":"Сопряжено с {name}. Уровень доверия: временный (можно изменить ниже).","errorNotAnyShare":"Устройство не является приложением AnyShare.","errorUnreachable":"Не удалось подключиться к устройству.","errorBusy":"Устройство занято другим сопряжением.","errorRejected":"В сопряжении отказано.","errorProtocol":"Неожиданный ответ сопряжения."},
  "incoming": {"title":"Запрос сопряжения","body":"{name} запрашивает сопряжение. Убедитесь, что на обоих экранах один и тот же код:","match":"Коды совпадают","mismatch":"Коды различаются"},
  "send": {"title":"Отправленные файлы","empty":"Отправленных файлов пока нет"},
 },
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for loc, data in TR.items():
    path = os.path.join(ROOT, 'app', 'assets', 'i18n', loc + '.json')
    try:
        d = json.load(io.open(path, encoding='utf-8'))
    except FileNotFoundError:
        print(loc, ': file missing, skip')
        continue
    d.setdefault('deviceDetailsPage', {})
    d['deviceDetailsPage']['trust'] = data['trust']
    d['deviceDetailsPage']['pairing'] = data['pairing']
    d['pairingIncoming'] = data['incoming']
    d['sendHistoryPage'] = data['send']
    io.open(path, 'w', encoding='utf-8', newline='\n').write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
    print(loc, 'patched')
