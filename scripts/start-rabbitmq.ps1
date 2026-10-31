<#
  Starts the local RabbitMQ broker as a background user process (hidden window).
  AMQP: localhost:5672 · Management UI: http://localhost:15672 (user "studio", password in backend/.env)

  Why not the Windows service: on this machine the RabbitMQ service exits with
  1067 before Erlang logs anything; the same broker runs fine as a user process.
#>
$env:ERLANG_HOME = 'C:\Program Files\Erlang OTP'
$sbin = 'C:\Program Files\RabbitMQ Server\rabbitmq_server-4.4.0\sbin'

if (Test-NetConnection localhost -Port 5672 -InformationLevel Quiet -WarningAction SilentlyContinue) {
    'RabbitMQ already running on 5672'; return
}
Start-Process -FilePath "$sbin\rabbitmq-server.bat" -WindowStyle Hidden
for ($i = 0; $i -lt 40; $i++) {
    if (Test-NetConnection localhost -Port 5672 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        'RabbitMQ started: amqp://localhost:5672  UI: http://localhost:15672'; return
    }
    Start-Sleep -Milliseconds 1500
}
throw "RabbitMQ did not open port 5672. Log: $env:APPDATA\RabbitMQ\log"
