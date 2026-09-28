#!/usr/bin/env php
<?php
declare(strict_types=1);

/**
 * kas-probe.php: prüft, ob die All-Inkl KAS-API die undokumentierten
 * DKIM-Funktionen (get_dkim, add_dkim, delete_dkim) kennt.
 *
 * Nur lesende Aufrufe: add_session, get_domains, get_dkim, delete_session.
 * add_dkim und delete_dkim werden NICHT aufgerufen.
 *
 * Aufruf:  php tools/kas-probe.php <domain> [<kas-login>] [--dump <verzeichnis>]
 * Mit --dump werden Roh-Request und Roh-Antwort jedes SOAP-Aufrufs als XML in das
 * Verzeichnis geschrieben (Passwort und Token werden maskiert). Dient als Test-Fixture.
 * Login und Passwort werden interaktiv abgefragt, das Passwort ohne Echo.
 * Bei aktiver 2FA wird nach dem OTP gefragt (leer lassen, wenn keine 2FA).
 */

const KAS_AUTH_WSDL = 'https://kasapi.kasserver.com/soap/wsdl/KasAuth.wsdl';
const KAS_API_WSDL  = 'https://kasapi.kasserver.com/soap/wsdl/KasApi.wsdl';

$args = array_values(array_filter(array_slice($argv, 1), fn($a) => $a !== '--dump'));
$dumpDir = null;
if (($i = array_search('--dump', $argv, true)) !== false) {
    $dumpDir = $argv[$i + 1] ?? null;
    $args = array_values(array_filter($args, fn($a) => $a !== $dumpDir));
    if ($dumpDir === null) { fwrite(STDERR, "--dump braucht ein Verzeichnis\n"); exit(2); }
    @mkdir($dumpDir, 0700, true);
}
$host  = $args[0] ?? null;
$login = $args[1] ?? null;

if ($host === null) {
    fwrite(STDERR, "Aufruf: php tools/kas-probe.php <domain> [<kas-login>]\n");
    exit(2);
}
if ($login === null) {
    $login = prompt('KAS-Login (z. B. w0123456):');
}
$password = promptHidden('KAS-Passwort: ');
$otp      = prompt('2FA-OTP (leer, wenn keine 2FA): ');

$auth = new SoapClient(KAS_AUTH_WSDL, ['exceptions' => true, 'trace' => true]);
$api  = new SoapClient(KAS_API_WSDL,  ['exceptions' => true, 'trace' => true]);

$dumpCounter = 0;
$dump = function (SoapClient $client, string $name, array $mask) use (&$dumpCounter, $dumpDir): void {
    if ($dumpDir === null) { return; }
    $dumpCounter++;
    foreach (['request' => $client->__getLastRequest(), 'response' => $client->__getLastResponse()] as $kind => $xml) {
        if ($xml === null) { continue; }
        foreach ($mask as $secret) {
            if ($secret !== '' ) { $xml = str_replace($secret, '***', $xml); }
        }
        file_put_contents(sprintf('%s/%02d-%s-%s.xml', $dumpDir, $dumpCounter, $name, $kind), $xml);
    }
};

// 1. Session anlegen (KasAuth)
$sessionParams = [
    'kas_login'               => $login,
    'kas_auth_type'           => 'plain',
    'kas_auth_data'           => $password,
    'session_lifetime'        => 600,
    'session_update_lifetime' => 'Y',
];
if ($otp !== '') {
    $sessionParams['session_2fa'] = $otp;
}
unset($password);

try {
    $token = $auth->KasAuth(json_encode($sessionParams, JSON_THROW_ON_ERROR));
    $dump($auth, 'kasauth', [$sessionParams['kas_auth_data'], (string) $token]);
    echo "[ok] Session angelegt, Token-Länge " . strlen((string) $token) . "\n";
} catch (SoapFault $e) {
    $dump($auth, 'kasauth-fault', [$sessionParams['kas_auth_data']]);
    echo "[fehler] KasAuth: " . $e->faultstring . "\n";
    exit(1);
}

$call = function (string $action, array $params = []) use ($api, $login, $token, $dump): ?array {
    $request = [
        'kas_login'        => $login,
        'kas_auth_type'    => 'session',
        'kas_auth_data'    => $token,
        'kas_action'       => $action,
        'KasRequestParams' => (object) $params,
    ];
    try {
        $raw = $api->KasApi(json_encode($request, JSON_THROW_ON_ERROR));
        $dump($api, $action, [$token]);
        $res = json_decode(json_encode($raw), true);
        $delay = (float) ($res['Response']['KasFloodDelay'] ?? 0);
        if ($delay > 0) {
            usleep((int) ($delay * 1_000_000));
        }
        return $res;
    } catch (SoapFault $e) {
        $dump($api, $action . '-fault', [$token]);
        echo "[fault] $action: " . $e->faultstring . "\n";
        // Flood-Schutz: kurz warten, damit Folgeaufrufe nicht ebenfalls scheitern
        usleep(1_500_000);
        return null;
    }
};

// 2. Kontrollaufruf: dokumentierte Funktion, beweist dass die Session trägt
$domains = $call('get_domains');
if ($domains !== null) {
    $names = array_column($domains['Response']['ReturnInfo'] ?? [], 'domain_name');
    echo "[ok] get_domains: " . count($names) . " Domains" . ($names ? " (" . implode(', ', $names) . ")" : '') . "\n";
}

// 3. Die eigentliche Frage
echo "\n=== get_dkim host=$host ===\n";
$dkim = $call('get_dkim', ['host' => $host]);
if ($dkim !== null) {
    echo json_encode($dkim['Response'] ?? $dkim, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
}

// Zweiter Versuch mit dem bei KAS sonst üblichen Parameternamen, falls 'host' unbekannt war
if ($dkim === null) {
    echo "\n=== get_dkim domain_name=$host (Alternativparameter) ===\n";
    $dkim2 = $call('get_dkim', ['domain_name' => $host]);
    if ($dkim2 !== null) {
        echo json_encode($dkim2['Response'] ?? $dkim2, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
    }
}

// 3b. Weitere lesende Aufrufe als Fixtures (nur mit --dump)
if ($dumpDir !== null) {
    foreach (['get_mailaccounts', 'get_mailforwards', 'get_subdomains', 'get_ftpusers', 'get_databases', 'get_cronjobs'] as $a) {
        $call($a);
    }
    $call('get_dns_settings', ['zone_host' => $host . '.']);
    $call('get_dns_settings', ['zone_host' => 'gibt-es-nicht-' . $host . '.']); // erwarteter Fehler als Fixture
    echo "[ok] Fixtures nach $dumpDir geschrieben (" . $dumpCounter . " Aufrufe)\n";
}

// 4. Session wieder schließen
$call('delete_session');
echo "\n[ok] Session geschlossen.\n";
echo "Auswertung: Erscheint oben ein Fault wie 'unknown_action' oder 'kas_action', kennt die API get_dkim nicht.\n";
echo "Erscheint eine Antwort mit ReturnInfo (Selector, Key, Status), ist DKIM per API lesbar.\n";

function prompt(string $label): string
{
    echo $label;
    return trim((string) fgets(STDIN));
}

function promptHidden(string $label): string
{
    echo $label;
    shell_exec('stty -echo');
    $value = trim((string) fgets(STDIN));
    shell_exec('stty echo');
    echo "\n";
    return $value;
}
