define('FORCE_SSL_ADMIN', true);

if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && $_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https')
$_SERVER['HTTPS']='on';
