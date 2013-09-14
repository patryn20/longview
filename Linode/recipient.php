<?php
$gzip_contents = file_get_contents($_FILES['data']['tmp_name']);

$json = gzdecode($gzip_contents);

$obj = json_decode($json);

error_log(print_r($obj, true));

$response_object = new StdClass();
$response_object->sleep = 10;

header("HTTP/1.1 200 OK");
echo json_encode($response_object);
