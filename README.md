<!--
  NOTA INTERNA (no se ve en GitHub): este README es la entrega E01 de DeepSeek, revisada por Claude.
  Pendiente antes de publicar:
  1. {{GIF_DEMO}} sigue pendiente (falta grabar). Los demás marcadores ya se resolvieron hoy.
  2. El nombre del botón de macOS 15 («Abrir de todos modos») está [VERIFICAR en macOS 15]: la guía en PDF
     dice «Abrir igualmente». Ver Encargos DeepSeek/fuentes/CORRECCIONES-2026-09-17.md
  3. El título y la línea de arriba se pueden ajustar al gusto de Alejandro.
-->

# OkiPaste

Historial de portapapeles para Mac. **Gratis, para usuarios Mac y no se conecta a internet.**

<!-- Demo pendiente: se agrega el GIF cuando exista la grabación. -->

---

## Por qué la hice

Estaba escribiendo mi tesis, reuniendo información de varias fuentes y de mis propias notas médicas. En el hospital, con Windows, el historial del portapapeles ya venía de fábrica: nunca perdía nada. En mi Mac, de noche, sí. Soy cirujano general y no sé programar, pero no quise resignarme: con ayuda de inteligencia artificial hice OkiPaste, y hoy la uso todos los días.

## Qué hace

- Guarda **todo lo que copias**: texto, texto con formato, enlaces, colores, imágenes, videos, PDF y varios archivos a la vez.
- Con **⌃⌥⌘V** aparece una barra con tus últimas copias, en la pantalla donde tengas el mouse.
- Haces clic en una tarjeta (o usas el teclado) y **se pega sola** en la app donde estabas.
- Escribes con la barra abierta y **filtra sola**, sin buscar ningún cuadro de búsqueda.
- Guarda **25 cosas como máximo** y **se borra sola al cambiar el día**.
- **Protege las contraseñas de tus gestores:** las que copias desde **1Password, Enpass** u otro gestor que marca "no guardar esto" no entran al historial. Una contraseña que escribas a mano en una nota sí se guarda como cualquier texto; por eso conviene no dejarlas en notas.

## Requisitos

| | |
|---|---|
| Sistema | macOS 12 (Monterey) o más nuevo |
| Procesador | Universal: Intel y Apple Silicon (M1, M2, M3, M4…) |
| Cuenta | Ninguna. No hay que registrarse ni iniciar sesión |
| Internet | No lo necesita, ni para instalarla ni para usarla |

No hay versión para Windows ni para iPhone. Es solo para Mac.

## Cómo instalarla

Descarga **`OkiPaste.dmg`** desde la [página de descarga](https://ocampo-murguia.github.io/OkiPaste/) o desde la sección de *Releases* de este repositorio.

Al abrir el `.dmg` vas a ver tres cosas: `OkiPaste.app`, un acceso a la carpeta **Aplicaciones** y la `Guía OkiPaste.pdf`.

### Si tienes macOS 14 (Sonoma) o anterior

1. **Descarga el archivo.** Espera a que aparezca `OkiPaste.dmg` en tu carpeta **Descargas**.
2. **Abre el disco.** Haz doble clic en `OkiPaste.dmg`.
3. **Arrastra la app.** Lleva el ícono de OkiPaste hasta la carpeta **Aplicaciones**.
4. **Ábrela.** Entra a **Aplicaciones**, haz **clic derecho** sobre OkiPaste → **Abrir** → y otra vez **Abrir**.
5. **Dale permiso.** macOS te pedirá el permiso de **Accesibilidad**: actívalo (ver abajo).

### Si tienes macOS 15 (Sequoia) o más nuevo

1. **Descarga el archivo.** Espera a que aparezca `OkiPaste.dmg` en tu carpeta **Descargas**.
2. **Abre el disco.** Haz doble clic en `OkiPaste.dmg`.
3. **Arrastra la app.** Lleva el ícono de OkiPaste hasta la carpeta **Aplicaciones**.
4. **Intenta abrirla.** Entra a **Aplicaciones** y haz doble clic en OkiPaste. Va a salir un aviso que dice que Apple no puede verificar la app. **Cierra ese aviso** (no la mandes a la papelera).
5. **Permítele abrirse.** Ve al menú Apple → **Ajustes del Sistema** → **Privacidad y seguridad**. Baja hasta el final y busca el mensaje sobre OkiPaste. Pulsa **Abrir de todos modos** y escribe tu contraseña. Después ábrela otra vez desde Aplicaciones.
6. **Dale permiso.** macOS te pedirá el permiso de **Accesibilidad**: actívalo (ver abajo).

### Por qué sale el aviso de Apple

OkiPaste es gratis y **no está notarizada** por Apple: Apple cobra por ese trámite cada año y no lo pagué. El aviso **no** significa que la app tenga algo malo — significa que Apple no la revisó. Por eso el código está aquí, a la vista de cualquiera que quiera leerlo.

Es el mismo aviso que macOS le pone a cualquier app que no pasó por su revisión.

## Permiso de Accesibilidad

OkiPaste necesita el permiso de **Accesibilidad** para poder pegar por ti. Sin ese permiso la barra abre y se ve, pero no puede pegar.

La app te lo pide sola la primera vez que la abres: haz clic en **Abrir Ajustes del Sistema** y activa el interruptor junto a OkiPaste.

Si ya cerraste el aviso y no lo activaste:

1. Menú Apple → **Ajustes del Sistema**.
2. **Privacidad y seguridad** → **Accesibilidad**.
3. Activa el interruptor junto a **OkiPaste**.

## Cómo usarla

La app se abre sola cada vez que prendes la Mac. No tienes que hacer nada para que empiece a guardar: funciona sola, en segundo plano.

**El único atajo que necesitas: ⌃ Control + ⌥ Option + ⌘ Command + V**

| Atajo | Qué hace |
|---|---|
| **⌃⌥⌘V** | Abre la barra con tus últimas copias |
| **Clic** en una tarjeta | Pega esa tarjeta donde estabas |
| **← →** | Te mueves entre tarjetas |
| **Enter** | Pega la tarjeta seleccionada |
| **⌘1 … ⌘9** | Pega directo la tarjeta de esa posición |
| **Escribir** | Filtra el historial mientras escribes |
| **⇧ Enter** | Pega solo el texto, sin el formato original |
| **⌘ ⌫** | Elimina esa tarjeta del historial |
| **Esc** | Cierra la barra sin pegar nada |

Con **clic derecho** en una tarjeta tienes más opciones: pegar, pegar como texto simple, copiar sin pegar, mostrar en Finder (solo archivos) y eliminar del historial.

En la **barra de menú**, arriba junto al reloj, está el ícono de OkiPaste. Ahí ves cuántas cosas tienes guardadas, y tienes **Mostrar historial**, **Borrar historial ahora**, **Salir de OkiPaste** y **Desinstalar OkiPaste…**

## Tu privacidad

- **No se conecta a internet.** No envía nada a ningún lado: no hay cuentas, ni anuncios, ni servidores.
- Tu historial vive **solo en tu Mac**, en una carpeta llamada `OkiPaste` dentro de tu carpeta de usuario.
- **No guarda las contraseñas de tus gestores:** reconoce lo que copias desde **1Password, Enpass** y los que marcan "no guardar esto". Una contraseña escrita a mano en una nota sí se guarda como cualquier texto.
- El historial se guarda en **archivos normales, sin cifrar** — igual de protegido que cualquier otro archivo de tu cuenta.
- El historial **se borra solo cada día**, y puedes vaciarlo cuando quieras desde el menú del ícono.
- Al desinstalarla, se va también el historial.

## Cómo desinstalarla

1. Haz clic en el ícono de OkiPaste en la **barra de menú**.
2. Elige **Desinstalar OkiPaste…** y confirma.

Se quita la app, el historial, el inicio automático y el permiso de Accesibilidad. No deja nada regado.

## ¿Ideas o errores?

Si algo no funcionó, si un paso no se entiende o si se te ocurre algo que le falta, cuéntame aquí: **https://forms.gle/vfQLNd4XpR9w6BHv7**

Sirve mucho que me digas en qué paso te trabaste. Con eso puedo arreglarlo.

## Código fuente

La app entera está en un solo archivo: `Source/main.swift` (Swift, sin librerías de terceros). Se puede leer de principio a fin.

`Source/build.sh` es el script que uso para compilarla como binario universal (Intel + Apple Silicon) y firmarla. **Ojo:** ese script asume que la app vive en `~/OkiPaste/OkiPaste.app`, que es mi carpeta de trabajo; si lo corres tal cual, escribe ahí. Está incluido como referencia de cómo se compila, no como instalador.

Se compila con las herramientas de Apple (`swiftc` y `lipo`), que vienen con Xcode o con las Command Line Tools.

## Licencia

MIT. Puedes leer el código, aprender de él y reusarlo. El texto completo está en [LICENSE](LICENSE).

Hecha por un cirujano general con ayuda de IA.
