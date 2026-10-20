# Avisos de terceiros

## playactor (licença ISC)

As tabelas de chaves do PS5 e o esquema de registro de `mac_app/PlayStationRemote.swift` seguem o
[playactor](https://github.com/dhleong/playactor), de Daniel Leong, distribuído sob a licença ISC
(campo `license` do `package.json`; o repositório não traz um arquivo LICENSE). Texto da licença:

> Permission to use, copy, modify, and/or distribute this software for any purpose with or without
> fee is hereby granted, provided that the above copyright notice and this permission notice appear
> in all copies.
>
> THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS
> SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
> AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
> WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
> NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
> OF THIS SOFTWARE.

## chiaki-ng (AGPL-3.0)

O [chiaki-ng](https://github.com/streetpea/chiaki-ng) serviu só de referência do protocolo do Remote
Play e para conferir que as tabelas de chaves do playactor são idênticas às dele. Nenhum código do
chiaki-ng foi copiado para este repositório.

## Constantes públicas do Remote Play

O identificador e o segredo do cliente OAuth em `PlayStationRemote.swift` são os do app Remote Play
para Windows, publicados nos projetos acima. Não são credenciais de ninguém deste repositório.
