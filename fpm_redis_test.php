<?php
$r = new Redis();
$r->connect("redis", 6379);
$r->set("fpm:test", "ok_from_php_fpm");
echo json_encode([
  "loaded" => extension_loaded("redis"),
  "version" => phpversion("redis"),
  "ping" => $r->ping(),
  "value" => $r->get("fpm:test"),
]);
