// ARCHIVO GENERADO por aplicar_ips.py a partir de plantillas/config_red.dart.
// Para cambiar la IP virtual o el puerto edite ips.env y ejecute:
//     python aplicar_ips.py

/// IP virtual de Keepalived (la ÚNICA dirección que conoce la app).
const String ipVirtual = '10.79.7.200';

/// Puerto donde atiende NGINX en cada servidor.
const int puertoNginx = 90;
