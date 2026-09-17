# Seguridad

OkiPaste toca el portapapeles del sistema y necesita el permiso de Accesibilidad de macOS para pegar. Si encuentras un problema de seguridad o privacidad (no un error normal de uso), repórtalo por separado de los issues públicos de GitHub, para que no quede expuesto antes de tener una corrección:

- Abre un **Security Advisory** privado desde la pestaña "Security" del repositorio (GitHub → Security → Report a vulnerability), o
- Escribe directamente a {{CORREO_SEGURIDAD}} con el detalle de cómo reproducirlo.

No se requiere ningún trato de "recompensa" ni de respuesta en tiempo garantizado: este es un proyecto de una sola persona. Se atienden reportes serios con la máxima prioridad posible.

## Qué SÍ hace OkiPaste con tus datos
- El historial se guarda sin cifrar en `~/OkiPaste/Historial`, en formato JSON + los archivos originales (imágenes PNG, RTF). Cualquier proceso con acceso a esa carpeta de tu cuenta puede leerlo.
- El contenido marcado como confidencial por gestores de contraseñas (1Password y similares, vía los tipos de datos `org.nspasteboard.*`) se excluye antes de guardarse — nunca llega a disco.
- El historial se borra solo, completo, al cambiar el día calendario, y también se puede borrar manualmente desde el menú.
- Nada sale de la Mac: no hay red, no hay telemetría, no hay servidor.

## Qué NO hace (y por qué importa)
- No cifra el historial en reposo. Si tu cuenta de macOS no tiene FileVault activado, cualquier persona con acceso físico al disco puede leer `~/OkiPaste/Historial`.
- No filtra contenido sensible que no venga marcado como confidencial por la app de origen (por ejemplo, si copias manualmente un dato sensible de un documento de texto, se guarda igual que cualquier otro texto, hasta que se borre al otro día).
