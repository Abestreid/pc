<?php
// Install outside the domain document root: /hosting1/abeslabby/pc-inventory-data/config.php
// Generate rate_salt using bin2hex(random_bytes(32)); never commit the real configuration.
return [
    'storage' => __DIR__,
    'base_url' => 'https://test.abeslab.by/pc',
    'rate_salt' => 'REPLACE_WITH_64_RANDOM_HEX_CHARACTERS',
];
