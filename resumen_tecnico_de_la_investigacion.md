# Resumen de la investigación — Programa Delfín

> Texto listo para copiar y pegar en los cuatro campos del formulario de "Información del Resumen" (Planteamiento, Metodología, Conclusiones, Referencias). Redactado como párrafos continuos, sin bloques de código ni tablas, para que se vea bien dentro de un editor de texto enriquecido.

---

## Planteamiento

HuronOS es la distribución de Linux oficial de la Olimpiada Mexicana de Informática (OMI) y del ICPC, diseñada específicamente para reforzar la integridad de exámenes y concursos de programación mediante el bloqueo de dispositivos USB, la restricción de sitios web permitidos y la aplicación de horarios de examen. Sin embargo, en su forma oficial, HuronOS solo puede arrancar desde una memoria USB físicamente instalada en cada equipo: su proceso de inicio busca un dispositivo de bloques cuyo identificador coincida con el grabado en tiempo de instalación. En un laboratorio de cómputo con muchos equipos, esta limitación obliga a preparar y mantener una memoria USB por estación, impide centralizar la actualización de directivas de examen sin volver a grabar cada USB, y dificulta escalar el número de estaciones disponibles sin escalar también el número de memorias físicas.

Este trabajo parte de la pregunta de si es posible que HuronOS arranque de forma completa por red —kernel, sistema de archivos y directivas de examen incluidos— sin modificar el proyecto oficial de manera irreversible y sin perder ninguna de sus garantías de seguridad. El arranque por red para laboratorios de cómputo no es un problema nuevo: proyectos como LTSP (Linux Terminal Server Project) y FAI (Fully Automatic Installation) permiten que un laboratorio arranque una imagen Linux compartida vía PXE desde un servidor central, y Safe Exam Browser restringe un escritorio ya en ejecución a un entorno controlado para exámenes en línea. Sin embargo, ninguno de estos resuelve el problema específico de HuronOS: los primeros no incluyen un modelo de directivas de examen nativo, y el segundo asume que el sistema operativo y su conectividad ya están presentes localmente, sin abordar cómo ese sistema llega a la estación en primer lugar. HuronOS ocupa el espacio entre ambas líneas de trabajo, y este proyecto busca cerrar, específicamente para HuronOS, la brecha entre su mecanismo de aplicación de directivas y la capacidad de desplegarlo sin medios físicos.

Los objetivos concretos del proyecto fueron: lograr que el kernel y el sistema de arranque inicial de HuronOS soporten red; lograr que el sistema completo se descargue por HTTP en vez de buscarse en un USB físico; preservar intacto el mecanismo nativo de directivas de examen; resolver la persistencia del trabajo del usuario entre encendidos, dado que en red no existe una partición física donde guardarlo; y validar la solución completa primero en un entorno simulado y después en un piloto de hardware real, sin afectar en ningún momento el camino de arranque físico original de la distribución.

---

## Metodología

El trabajo se desarrolló como una investigación iterativa de prueba, diagnóstico y corrección. En cada etapa se planteó una hipótesis sobre la causa de un fallo de arranque, se instrumentó el sistema para confirmarla o descartarla —mediante shells interactivos en distintos puntos del arranque, lectura del código fuente oficial de HuronOS y de sus herramientas de compilación, y registros propios cuando las herramientas estándar de diagnóstico no alcanzaban a capturar la fase inicial de arranque—, y se aplicó una corrección mínima y aditiva, preferentemente en forma de capas adicionales o de banderas condicionadas, en vez de editar archivos originales de la distribución. Cada corrección se verificó arrancando de verdad el sistema, tanto en máquina virtual como en hardware real, y observando su comportamiento real, ya que varios de los problemas encontrados solo se manifestaban en tiempo de ejecución.

El primer paso fue diagnosticar por qué un intento directo de arranque por red fallaba: al revisar el repositorio oficial de herramientas de compilación de HuronOS se encontró que el kernel de la distribución ya incluye, compilados como módulos, los controladores de red necesarios tanto para hardware físico como para máquinas virtuales. Su ausencia en una imagen estándar no es una limitación del kernel, sino una decisión tomada en tiempo de compilación mediante una variable de entorno que, por diseño, se deja desactivada en las imágenes orientadas a USB. Este hallazgo permitió recompilar HuronOS activando esa variable, sin modificar la lógica propia de la distribución.

Sobre esa base se diseñó una arquitectura cliente-servidor: un equipo maestro expone, mediante contenedores, un servidor DHCP con entrega de arranque por iPXE, un servidor HTTP que sirve el script de arranque, el kernel y el sistema recompilados, la imagen del sistema de archivos, el catálogo de software y el archivo de directivas de examen, además de un servicio de persistencia identificado por dirección MAC. Sobre esa arquitectura se implementaron tres parches aditivos, activos únicamente cuando el sistema arranca en modo red: uno que sustituye la búsqueda de un dispositivo físico por la descarga del sistema completo vía HTTP; uno que permite descargar bajo demanda, desde el servidor maestro, únicamente el software que la directiva de examen activa solicite; y uno que sincroniza, también vía red e identificando cada equipo por su dirección MAC, el trabajo del usuario entre reinicios. La solución se validó primero por completo en un laboratorio simulado con máquinas virtuales, y posteriormente en un piloto de hardware real construido con una Raspberry Pi como equipo maestro, un router dedicado que aísla el segmento de examen del resto de la red, y una laptop física como primer cliente de arranque por red.

---

## Conclusiones

La investigación demuestra que una distribución de Linux diseñada exclusivamente para arrancar desde USB puede convertirse en un sistema de despliegue por red sin modificar su propia lógica de seguridad y de aplicación de directivas, identificando la causa real de la limitación —una decisión de compilación, no el kernel— y agregando solo un pequeño número de parches aditivos, activados detrás de una bandera explícita de arranque. La solución se validó primero en simulación y después, con los ajustes propios de firmware y equipo de red reales, en un piloto físico, lo que sugiere que el enfoque es aplicable a otras distribuciones centradas en USB que enfrenten la misma limitación de despliegue.

El hallazgo más relevante de todo el proyecto surgió precisamente al pasar de la simulación al hardware real: la persistencia del trabajo del usuario entre reinicios, ya validada por completo en el entorno simulado, falla en el piloto físico. Este resultado es, en sí mismo, la lección metodológica central del trabajo: la diferencia entre un apagado limpio de una máquina virtual y un reinicio físico real expuso una falla que ninguna prueba exclusivamente en simulación podía haber revelado. La severidad de esta limitación depende del caso de uso: en un examen, donde el trabajo del estudiante suele existir solo de forma local hasta la entrega final, perder la persistencia representa un riesgo real de pérdida de avance; en un concurso de programación, en cambio, el impacto es menor, ya que las soluciones se entregan de forma incremental a un juez en línea conforme se resuelven, por lo que perder el estado local no implica perder entregas ya calificadas.

Además de este hallazgo, el piloto de hardware real permitió documentar dos limitaciones de desempeño que no se manifestaron en la simulación: un tiempo de arranque de aproximadamente dos minutos y medio hasta llegar al escritorio, y un retraso adicional de aproximadamente dos minutos en la disponibilidad de software pesado solicitado por la directiva activa. Ambas se atribuyen, de forma preliminar, al mismo mecanismo de transporte usado para montar el sistema de archivos remoto, y quedan como agenda inmediata de trabajo futuro, junto con el diagnóstico definitivo de la falla de persistencia y la validación del piloto con múltiples estaciones físicas de forma simultánea.

---

## Referencias

Juárez Cruz, O. G., Ortiz-Bejar, J., y Cerda-Jacobo, J. (2026). *Deployment of Huron OS via iPXE Network Boot for Exam Labs*. Artículo sometido al ROPEC 2026 (IEEE International Autumn Meeting on Power, Electronics and Computing), Morelia, México.

Quetzalcoatl, E. et al. *huronOS-build-tools* [Repositorio de GitHub]. https://github.com/equetzal/huronOS-build-tools

Juárez Cruz, O. G. *huronos_directives: example exam/contest directive files* [Repositorio de GitHub]. https://github.com/Orlanstein/progDelfin_HuronOS_iPXE

iPXE Project. *iPXE: Open source network boot firmware*. https://ipxe.org

Kelley, S. *dnsmasq: A lightweight DHCP and caching DNS server*. https://thekelleys.org.uk/dnsmasq/doc.html

Intel Corporation and SystemSoft. (1999). *Preboot Execution Environment (PXE) Specification*, versión 2.1.

Docker Inc. *Docker Compose overview*. https://docs.docker.com/compose/

MikroTik. *RouterOS documentation*. https://help.mikrotik.com/docs/

LTSP Project. *LTSP: Linux Terminal Server Project*. https://ltsp.org

FAI Project. *FAI: Fully Automatic Installation*. https://fai-project.org

Safe Exam Browser Project. *Safe Exam Browser*. https://safeexambrowser.org
