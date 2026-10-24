# Luma Camera

App pessoal de câmera para iPhone 14, feito com SwiftUI e frameworks nativos da Apple. O processamento e as fotos ficam no aparelho; o app não inclui conta, análise remota ou envio de imagens.

## Abrir no iPhone

1. Abra `LumaCamera.xcodeproj` no Xcode em um Mac.
2. Em **Signing & Capabilities**, escolha sua equipe de desenvolvimento e, se necessário, altere o identificador `com.private.lumacamera`.
3. Selecione o iPhone 14 conectado e execute o app. A instalação privada no aparelho não exige publicação na App Store.

O projeto usa iOS 17 ou posterior. O projeto-fonte pode ser compilado em um serviço de build macOS na nuvem; a compilação ainda não foi executada.

## Compilar sem Mac

O arquivo `codemagic.yaml` prepara um build iOS sem assinatura e o empacota como `LumaCamera-unsigned.ipa`. Para disparar esse build, coloque o conteúdo desta pasta em um repositório **privado** no GitHub, conecte esse repositório ao Codemagic e selecione o workflow `Luma Camera - iOS unsigned build`. O Codemagic exige um repositório conectado para ler o YAML e executar o build.

O IPA resultante é sem assinatura e não instala diretamente ao tocar nele no iPhone. Baixe-o no PC Windows e use Sideloadly para assinar e instalar no iPhone conectado por USB usando seu Apple ID. Baixe o instalador somente do [site oficial do Sideloadly](https://sideloadly.io/). A assinatura gratuita de sideload tem prazo limitado e precisa ser renovada periodicamente. Nunca envie sua senha ou código Apple para o Codemagic ou para esta conversa; faça a autenticação do Apple ID localmente no instalador.

## Recursos

- Captura HEIC com prioridade de qualidade.
- Ajuste computacional leve de cor e nitidez.
- Retrato computacional com segmentação de pessoa e desfoque de fundo.
- Zoom de 1×, 1,5×, 2× e 3× pela câmera principal. Os níveis acima de 1× são zoom digital no iPhone 14.
- Exportação opcional TIFF chamada **ProRAW simulado**.

**Limite de hardware:** iPhone 14 não oferece Apple ProRAW. O modo marcado com asterisco salva um TIFF renderizado e editável com metadados; ele não contém os dados RAW do sensor e não equivale ao ProRAW de um iPhone Pro. Retrato usa segmentação de pessoa por software, então o recorte pode variar conforme iluminação e cena.

