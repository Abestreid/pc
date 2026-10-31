<?php
declare(strict_types=1);

// Configuration and reports live outside the document root.
ini_set('display_errors', '0');
date_default_timezone_set('Europe/Minsk');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
const MAX_ARCHIVE = 8388608;
const MAX_UNPACKED = 16777216;

function jsonReply(int $status, array $data): void {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function fail(int $status, string $message): void { jsonReply($status, ['ok' => false, 'error' => $message]); }
function h($value): string { return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

$configPath = getenv('PC_INVENTORY_CONFIG') ?: dirname(__DIR__, 2) . '/pc-inventory-data/config.php';
if (!is_file($configPath)) { fail(503, 'Хранилище ещё не настроено.'); }
$config = require $configPath;
$storage = $config['storage'];
$baseUrl = rtrim($config['base_url'], '/');
$rateSalt = $config['rate_salt'];
if (!is_dir($storage . '/reports') && !mkdir($storage . '/reports', 0700, true) && !is_dir($storage . '/reports')) {
    fail(503, 'Хранилище недоступно.');
}

$action = $_GET['action'] ?? '';
if ($action === 'health') { jsonReply(200, ['ok' => true, 'service' => 'pc-inventory', 'version' => '2.0']); }
if ($action === 'upload') {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') { header('Allow: POST'); fail(405, 'Используйте POST.'); }
    if (!class_exists('ZipArchive')) { fail(503, 'ZIP недоступен на сервере.'); }
    $timestamp = $_SERVER['HTTP_X_INVENTORY_TIMESTAMP'] ?? ($_POST['timestamp'] ?? '');
    $date = is_string($timestamp) ? DateTimeImmutable::createFromFormat('!dmYHis', $timestamp) : false;
    if (!$date || $date->format('dmYHis') !== $timestamp) { fail(400, 'Дата должна быть в формате ддммггггччммсс.'); }
    if ((int)($_SERVER['CONTENT_LENGTH'] ?? 0) > MAX_ARCHIVE + 65536) { fail(413, 'Максимальный размер архива — 8 МБ.'); }
    $temp = tempnam($storage, 'incoming-');
    if ($temp === false) { fail(503, 'Не удалось создать временный файл.'); }
    register_shutdown_function(static function () use ($temp) { if (is_file($temp)) { unlink($temp); } });
    if (isset($_FILES['archive'])) {
        if ($_FILES['archive']['error'] !== UPLOAD_ERR_OK || !is_uploaded_file($_FILES['archive']['tmp_name'])) { fail(400, 'Ошибка загрузки файла.'); }
        if (!move_uploaded_file($_FILES['archive']['tmp_name'], $temp)) { fail(503, 'Не удалось сохранить файл.'); }
    } else {
        if (strtolower(trim(explode(';', $_SERVER['CONTENT_TYPE'] ?? '')[0])) !== 'application/zip') { fail(415, 'Ожидается ZIP-архив.'); }
        $input = fopen('php://input', 'rb'); $output = fopen($temp, 'wb');
        if (!$input || !$output) { fail(503, 'Не удалось прочитать загрузку.'); }
        stream_copy_to_stream($input, $output, MAX_ARCHIVE + 1);
        fclose($input); fclose($output);
    }
    $bytes = filesize($temp);
    if (!$bytes || $bytes > MAX_ARCHIVE) { fail(413, 'Архив пуст или превышает 8 МБ.'); }
    $zip = new ZipArchive();
    if ($zip->open($temp, ZipArchive::CHECKCONS) !== true) { fail(400, 'Повреждённый ZIP-архив.'); }
    if ($zip->numFiles < 4 || $zip->numFiles > 50) { $zip->close(); fail(400, 'В архиве должно быть от 4 до 50 файлов отчёта.'); }
    $names = []; $total = 0;
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $stat = $zip->statIndex($i);
        $name = $stat['name'];
        if (!preg_match('/\A(?:inventory\.(?:json|txt|csv)|manual-checklist\.txt|smartctl-disk-\d+\.txt)\z/D', $name)
            || isset($names[$name]) || $stat['size'] > 4194304 || ($stat['encryption_method'] ?? 0) !== 0) {
            $zip->close(); fail(400, 'Недопустимые файлы в архиве.');
        }
        $names[$name] = true; $total += $stat['size'];
    }
    if ($total > MAX_UNPACKED || array_diff(['inventory.json','inventory.txt','inventory.csv','manual-checklist.txt'], array_keys($names))) {
        $zip->close(); fail(400, 'Неполный или слишком большой отчёт.');
    }
    $jsonText = $zip->getFromName('inventory.json');
    $jsonText = is_string($jsonText) ? preg_replace('/^\xEF\xBB\xBF/', '', $jsonText) : '';
    $inventory = json_decode($jsonText, true, 32);
    $zip->close();
    if (!is_array($inventory) || !isset($inventory['Version'], $inventory['ComputerName'], $inventory['CPU'], $inventory['RAM'])
        || !is_string($inventory['ComputerName']) || strlen($inventory['ComputerName']) > 256
        || !is_array($inventory['CPU']) || !is_array($inventory['RAM'])) { fail(400, 'Некорректный inventory.json.'); }
    $host = preg_replace('/[^A-Za-z0-9_.-]/', '_', $inventory['ComputerName']);
    $host = trim(substr($host, 0, 100), '.');
    if ($host === '') { $host = 'PC'; }
    $cpu = $inventory['CPU'][0]['Model'] ?? 'Не определён';
    $ram = $inventory['RAM']['TotalGB'] ?? null;
    if (!is_string($cpu) || strlen($cpu) > 1024 || (!is_null($ram) && !is_numeric($ram))) { fail(400, 'Некорректные CPU/RAM.'); }
    $lock = fopen($storage . '/upload.lock', 'c');
    if (!$lock || !flock($lock, LOCK_EX)) { fail(503, 'Хранилище занято.'); }
    try {
        $rateFile = $storage . '/rate.json';
        $rate = is_file($rateFile) ? (json_decode(file_get_contents($rateFile), true) ?: []) : [];
        $hour = date('YmdH');
        if (($rate['hour'] ?? '') !== $hour) { $rate = ['hour' => $hour, 'ips' => [], 'count' => 0]; }
        $ip = hash_hmac('sha256', $_SERVER['REMOTE_ADDR'] ?? 'unknown', $rateSalt);
        if (($rate['ips'][$ip] ?? 0) >= 15 || $rate['count'] >= 100) { fail(429, 'Лимит загрузок за час исчерпан. Повторите позднее.'); }
        $used = 0; $files = glob($storage . '/reports/*.zip') ?: [];
        foreach ($files as $file) { $used += filesize($file); }
        if ($used + $bytes > 536870912 || count($files) >= 2000) { fail(507, 'Хранилище заполнено. Локальный отчёт сохранён на ПК.'); }
        $id = bin2hex(random_bytes(16));
        $archive = $storage . '/reports/' . $id . '.zip';
        $sha = hash_file('sha256', $temp);
        $metadata = ['id' => $id, 'timestamp' => $timestamp, 'received_at' => date(DATE_ATOM), 'computer' => $inventory['ComputerName'], 'cpu' => $cpu, 'ram_gb' => $ram, 'filename' => $timestamp . '-' . $host . '.zip', 'bytes' => $bytes, 'sha256' => $sha];
        if (!rename($temp, $archive)) { fail(503, 'Не удалось сохранить архив.'); }
        chmod($archive, 0600);
        if (file_put_contents($storage . '/reports/' . $id . '.json', json_encode($metadata, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), LOCK_EX) === false) { fail(503, 'Не удалось сохранить описание отчёта.'); }
        $rate['ips'][$ip] = ($rate['ips'][$ip] ?? 0) + 1; $rate['count']++;
        file_put_contents($rateFile, json_encode($rate, JSON_THROW_ON_ERROR), LOCK_EX);
    } finally { flock($lock, LOCK_UN); fclose($lock); }
    jsonReply(201, ['ok' => true, 'url' => $baseUrl . '/?report=' . $id, 'filename' => $metadata['filename'], 'sha256' => $sha]);
}

$reportId = $_GET['report'] ?? '';
$selected = null;
if ($reportId !== '') {
    if (!is_string($reportId) || !preg_match('/\A[a-f0-9]{32}\z/D', $reportId)) { fail(404, 'Отчёт не найден.'); }
    $metaFile = $storage . '/reports/' . $reportId . '.json';
    if (!is_file($metaFile)) { fail(404, 'Отчёт не найден.'); }
    $selected = json_decode(file_get_contents($metaFile), true);
    if (!$selected) { fail(404, 'Отчёт не найден.'); }
    if ($action === 'download') {
        header('Content-Type: application/zip');
        header('Content-Disposition: attachment; filename="' . $selected['filename'] . '"');
        header('Content-Length: ' . filesize($storage . '/reports/' . $reportId . '.zip'));
        readfile($storage . '/reports/' . $reportId . '.zip'); exit;
    }
    if ($action === 'text') {
        $zip = new ZipArchive();
        if ($zip->open($storage . '/reports/' . $reportId . '.zip') !== true) { fail(500, 'Не удалось прочитать отчёт.'); }
        $text = $zip->getFromName('inventory.txt'); $zip->close();
        header('Content-Type: text/plain; charset=utf-8'); echo $text; exit;
    }
}
if ($action !== '' && $action !== 'download' && $action !== 'text') { fail(404, 'Страница не найдена.'); }
if (in_array($action, ['download','text'], true) && !$selected) { fail(404, 'Отчёт не найден.'); }
$reports = [];
if ($selected) { $reports[] = $selected; }
else {
    foreach (glob($storage . '/reports/*.json') ?: [] as $file) {
        $row = json_decode(file_get_contents($file), true);
        if (is_array($row)) { $reports[] = $row; }
    }
    usort($reports, static fn($a, $b) => strcmp($b['received_at'], $a['received_at']));
}
$command = trim(file_get_contents(__DIR__ . '/launch-command.txt'));
header('Content-Type: text/html; charset=utf-8');
?>
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Инвентаризация ПК · ABESLAB</title>
<style>
:root{font-family:Segoe UI,system-ui,sans-serif;color:#182c3d;background:#f3f6f8}*{box-sizing:border-box}body{margin:0}main{max-width:960px;margin:auto;padding:42px 22px 70px}.brand{font-size:13px;font-weight:700;letter-spacing:.15em;color:#296b65}h1{font-size:clamp(30px,6vw,46px);letter-spacing:-.04em;margin:28px 0 12px;line-height:1.12}p{line-height:1.65;color:#4a5c6c}.intro{max-width:670px;font-size:18px}.panel{background:white;border:1px solid #dce4e9;border-radius:18px;padding:26px;margin-top:24px}h2{margin:0 0 12px;font-size:21px}code{display:block;white-space:pre-wrap;overflow-wrap:anywhere;background:#142e3c;color:#e8f5f4;border-radius:12px;padding:18px;font-size:13px;line-height:1.65}button,.button{display:inline-block;background:#21685e;color:white;border:0;border-radius:9px;padding:12px 18px;font:inherit;font-weight:600;text-decoration:none;cursor:pointer;margin-top:14px}a{color:#21685e}small,.muted{color:#5e6d78;font-size:13px}.steps{display:flex;gap:16px;flex-wrap:wrap;margin:16px 0}.steps span{background:#eef5f4;border-radius:8px;padding:10px 14px}input{font:inherit;max-width:100%}.report{border-top:1px solid #e1e7eb;padding-top:18px;margin-top:18px}.report h3{margin:0;overflow-wrap:anywhere}.meta{display:flex;gap:16px;flex-wrap:wrap;font-size:14px;margin-top:10px}.links{display:flex;gap:16px;align-items:center;flex-wrap:wrap}.links a{margin:10px 0}.status{overflow-wrap:anywhere}footer{margin-top:28px;color:#5e6d78;font-size:13px}@media(max-width:600px){main{padding-top:28px}.panel{padding:20px}.steps{display:block}.steps span{display:block;margin-bottom:8px}}
</style></head><body><main>
<div class="brand">ABESLAB / PC</div>
<h1>Характеристики ПК.<br>Один запуск — готовый отчёт.</h1>
<p class="intro">Соберите конфигурацию Windows перед продажей. Отчёт сохранится на компьютере и отправится сюда автоматически — без GitHub-токена.</p>
<section class="panel"><h2>Запустить проверку</h2><p><a class="button" href="PcSaleInventory.cmd" download>Скачать запуск для Windows 7 / 10 / 11</a></p><p>Откройте скачанный CMD-файл — он возьмёт актуальный скрипт из GitHub и запустит сбор. Или выполните команду ниже:</p><div class="steps"><span>1. Откройте PowerShell от администратора</span><span>2. Вставьте команду и нажмите Enter</span></div>
<code id="command"><?= h($command) ?></code><button id="copy" type="button">Скопировать команду</button>
<p class="muted">Windows 7/10/11 · CPU, RAM, диски, GPU, плата, сеть и Windows. Системные настройки не меняются. После сбора появится индивидуальная ссылка на результат.</p></section>
<section class="panel"><h2>Уже есть ZIP-отчёт?</h2><p>Можно отправить архив, который сохранился после предыдущего запуска.</p>
<form id="upload"><label>Архив отчёта (до 8 МБ)<br><input type="file" name="archive" accept=".zip" required></label><br><button type="submit">Отправить отчёт</button></form><p class="status" id="status" aria-live="polite"></p></section>
<section class="panel"><h2><?= $selected ? 'Отчёт получен' : 'Все отчёты · ' . count($reports) ?></h2>
<?php if (!$reports): ?><p>Отчётов пока нет. Запустите команду на первом компьютере.</p><?php endif; ?>
<?php foreach ($reports as $row): ?>
<article class="report"><h3><?= h($row['computer']) ?></h3><p><?= h($row['cpu']) ?></p><div class="meta"><span>RAM: <?= h($row['ram_gb'] ?? '—') ?> ГБ</span><span>Получен: <?= h((new DateTimeImmutable($row['received_at']))->format('d.m.Y H:i:s')) ?></span><span><?= h($row['filename']) ?></span></div>
<div class="links"><a class="button" href="?action=download&amp;report=<?= h($row['id']) ?>">Скачать ZIP</a><a href="?action=text&amp;report=<?= h($row['id']) ?>">Открыть текст</a><a href="?report=<?= h($row['id']) ?>">Ссылка на отчёт</a></div></article>
<?php endforeach; ?></section>
<footer>Локальные копии: рабочий стол → PC-Sale-Inventory. Для сбора без отправки используйте -SkipUpload. Модель БП, порты и состояние корпуса проверяются вручную; Windows Healthy не заменяет SMART.</footer>
</main><script>
document.getElementById('copy').onclick=async function(){try{await navigator.clipboard.writeText(document.getElementById('command').textContent);this.textContent='Команда скопирована'}catch(e){this.textContent='Выделите команду и скопируйте вручную'}};
document.getElementById('upload').onsubmit=async function(e){e.preventDefault();const status=document.getElementById('status'),button=this.querySelector('button');button.disabled=true;status.textContent='Отправляем архив…';const now=new Date(),pad=n=>String(n).padStart(2,'0'),stamp=pad(now.getDate())+pad(now.getMonth()+1)+now.getFullYear()+pad(now.getHours())+pad(now.getMinutes())+pad(now.getSeconds()),data=new FormData(this);data.append('timestamp',stamp);try{const response=await fetch('?action=upload',{method:'POST',body:data});const result=await response.json();if(!response.ok||!result.ok)throw new Error(result.error||'Ошибка отправки');location.href=result.url}catch(err){status.textContent=err.message;button.disabled=false}};
</script></body></html>
