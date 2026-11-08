# infra-comun

Este repo tiene las plantillas y los workflows que comparten los proyectos en AWS y Vercel.

## La regla: dónde vive cada cosa

| Qué es | Dónde va |
|---|---|
| HTML estático (landing, portafolio, sitio de cliente) | S3 + CloudFront, con `estatico/` |
| Frontend con SSR o ISR | Vercel, sin crons ni funciones largas |
| API, webhook, cron, lote o IA | Lambda. Cada repo usa la herramienta que ya tiene (SAM o Serverless). |
| Formulario de contacto de un sitio estático | Lambda + SES, con `contacto/`, servida en `/api/*` del mismo dominio |
| Crons | EventBridge Scheduler → Lambda. Nunca un cron de Vercel. |
| DNS | Vercel DNS. Si hay certificados de ACM, agregar CAA de Amazon. |

Además:

- Todo recurso de AWS lleva la etiqueta `proyecto=<x>`, que se usa para separar los costos.
- Los despliegues van por OIDC: un rol por repo, limitado a `main`. No se usan llaves fijas.

## Despliegue: cada pieza sale sola cuando cambia

- **Sitio estático:** `on: push` con `paths:` del sitio, que llama al reusable workflow `deploy-estatico.yml`. El ejemplo de uso está en el encabezado de ese archivo.
- **Infra (los templates):** se aplica a mano con `scripts/aplicar.sh`, que por defecto es un dry-run.

## Sitio estático nuevo

1. **Probar sin dominio.** Corre `scripts/aplicar.sh estatico <stack> <proyecto> Repo=GonzaloAfa/<repo>`, revisa los cambios que muestra y repite con `--apply`. Queda en `*.cloudfront.net`.
2. **Configurar el repo.** En GitHub, crea la variable `AWS_DEPLOY_ROLE_ARN` con el valor del output `RolDeployArn`, y agrega el workflow que llama a `deploy-estatico.yml`.
3. **Pedir el certificado** de ACM en us-east-1 para el dominio y su `www`, con validación por DNS. Crea el CNAME de validación en Vercel DNS.
4. **Volver a aplicar el stack** con `DominioCanonico=…`, `DominiosExtra=www.…` y `CertificadoArn=…`.
5. **Hacer el corte.** En Vercel DNS, apunta el apex con un ALIAS y `www` con un CNAME al output `CloudFrontHost`. El proyecto de Vercel queda como rollback unas semanas y después se pausa.

## Sitio estático que ya existía

Para un sitio cuyo bucket y CloudFront se crearon antes de `estatico/` y solo hay que sacarle las llaves fijas:

```
scripts/aplicar.sh oidc-estatico <proyecto>-deploy <proyecto> Repo=GonzaloAfa/<repo> Bucket=<bucket> DistribucionId=<id> [Funcion=<lambda>] --apply
```

Crea solo el rol (subir al bucket, invalidar la distribución y, si se pasa `Funcion`, actualizar el código de esa Lambda). El output `RolDeployArn` va en la variable `AWS_DEPLOY_ROLE_ARN` del repo, y el workflow usa `role-to-assume` en vez de las llaves. Como expone `Bucket` y `DistribucionId`, también sirve con `deploy-estatico.yml`. En uso: `afachile-deploy` (afachile.cl) y `futbol-deploy` (futbol.afachile.cl).

## Formulario de contacto

Se envía por **SES (us-east-1)**, que está en producción en la cuenta. No hace falta una clave: la Lambda envía con su rol, y solo puede hacerlo desde su propia identidad.

1. **Verificar el dominio en SES:** `aws sesv2 create-email-identity --email-identity <dominio>` y luego crear los 3 CNAME de DKIM en Vercel DNS. Otra opción es usar un dominio que ya esté verificado, como `afachile.cl`.
2. **Aplicar el stack de contacto:**
   ```
   scripts/aplicar.sh contacto <proyecto>-contacto <proyecto> IdentidadSes=<dominio> Remitente="Web <web@dominio>" Destino=… ApiSecreto=<32+ caracteres>
   ```
3. **Conectarlo al sitio.** El output `ApiHost` va como `ApiOrigen` del stack estático, junto con el mismo `ApiSecreto`. El sitio llama `fetch('/api/…')`, en el mismo dominio y sin CORS.

## Crons de una app que vive en Vercel

Vercel Hobby solo permite crons diarios. `cron-http/` programa en EventBridge Scheduler una Lambda mínima que hace GET a cada ruta con `Authorization: Bearer <CronSecret>`:

```
scripts/aplicar.sh cron-http <proyecto>-cron <proyecto> BaseUrl=https://… CronSecret=<CRON_SECRET de la app> \
  Tarea1='/api/cron/x|rate(10 minutes)' Tarea2='/api/cron/y|cron(0 */6 * * ? *)' [TimeoutSegundos=310] --apply
```

Hasta 6 tareas (`ruta|expresión`, hora de `America/Santiago`). `Activo=DISABLED` las pausa sin borrar nada. Cada corrida queda en `/aws/lambda/<proyecto>-cron-http` (14 días); una respuesta que no sea 2xx aparece como error de la Lambda.
