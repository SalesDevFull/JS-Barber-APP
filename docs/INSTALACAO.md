# JS Barber APP — guia técnico de instalação

Este projeto é o seu app, hospedado em contas suas.

| Arquivo | O que é |
|---|---|
| `index.html` | Painel do dono e dos barbeiros (login, agenda, caixa, clientes, gestão) |
| `agendar.html` | Página pública onde o cliente final agenda (e paga o sinal), sem precisar de conta |
| `admin.html` | Seu painel de administrador do sistema |
| `pix.js` | Gera o código Pix "copia e cola" do sinal |
| `config.js` | Onde ficam os dados de conexão do Supabase |
| `supabase/schema.sql` | O banco de dados: tabelas, regras de acesso e funções |
| `manifest.webmanifest`, `*.png` | Nome e ícone do app na tela do celular |
| `vercel.json` | Ajustes pro ícone e as atualizações aparecerem certinho na Vercel |
| `mascote.svg` | O mascote (barbeiro bigodudo), caso queira usar em posts ou no Instagram |

## Atualizando uma versão que já está no ar

1. **Banco:** no Supabase, **SQL Editor**, cole o `supabase/schema.sql` inteiro de novo e clique em **Run**. Ele não apaga nada, só acrescenta o que é novo.
2. **Site:** substitua **todos** os arquivos do seu repositório (ou da pasta do Netlify) pelos desta versão, mantendo o seu `config.js`. Na Vercel, a publicação acontece sozinha depois do envio pro GitHub.
3. **Ícone no celular:** apague o atalho antigo da tela de início e adicione de novo. O celular guarda o ícone velho e não troca sozinho.

Cada barbearia que assina tem seu próprio espaço. Uma não enxerga os dados da outra, e você, como dono do sistema, controla tudo pelo painel do Supabase.

---

## Passo 1 — Criar o banco de dados (Supabase)

1. Crie uma conta em **supabase.com** e clique em **New project**.
   - Nome: `barbearia-app` (ou o nome da sua marca).
   - Senha do banco: gere uma e **guarde** num lugar seguro.
   - Região: **South America (São Paulo)**.
2. Quando o projeto terminar de criar, abra **SQL Editor** (menu da esquerda) → **New query**.
3. Abra o arquivo `supabase/schema.sql`, copie **tudo**, cole no editor e clique em **Run**.
   Deve aparecer "Success". Se rodar de novo, não tem problema: ele não apaga nada.
4. Vá em **Project Settings → API** e copie dois valores:
   - **Project URL** (algo como `https://abcdefgh.supabase.co`)
   - **anon public** key (uma chave longa)
5. Abra `config.js` num editor de texto e cole esses dois valores no lugar de `COLE_AQUI_...`.

> A chave **anon** pode ficar no site, é feita pra isso. Quem protege os dados são as regras do banco (já estão no `schema.sql`).
> **Nunca** coloque a chave `service_role` no `config.js`.

## Passo 2 — Colocar o site no ar

### Opção A: Netlify, arrastando a pasta (mais rápido, 2 minutos)
1. Crie uma conta em **netlify.com**.
2. Vá em **Add new site → Deploy manually**.
3. Arraste a pasta inteira `barbearia-app` (com o `config.js` já preenchido) pra área indicada.
4. Pronto: o Netlify te dá um endereço tipo `https://nome-aleatorio.netlify.app`. Dá pra trocar o nome em **Site configuration → Change site name**.

Pra atualizar depois, é só arrastar a pasta de novo em **Deploys**.

### Opção B: GitHub + Vercel (melhor pra ir evoluindo o app)
1. Crie um repositório no **github.com** e suba os arquivos desta pasta.
2. Em **vercel.com**, clique em **Add New → Project**, escolha o repositório e clique em **Deploy** (não precisa mudar nenhuma configuração).
3. A cada alteração enviada pro GitHub, a Vercel publica sozinha.

## Passo 3 — Avisar o Supabase qual é o endereço do seu site

No Supabase: **Authentication → URL Configuration**
- **Site URL**: o endereço do seu site (ex.: `https://minhabarbearia.netlify.app`)
- **Redirect URLs**: adicione o mesmo endereço com `/**` no final

Sem isso, os links de confirmação de e-mail e de "esqueci a senha" levam pro lugar errado.

**Dica pra fase de testes:** em **Authentication → Sign In / Providers → Email**, você pode desligar **Confirm email**. Assim a conta funciona na hora, sem esperar e-mail. O envio de e-mails do plano grátis do Supabase é limitado a poucos por hora; quando for vender de verdade, configure um SMTP próprio em **Authentication → Emails → SMTP Settings** (Resend, Brevo, Amazon SES etc.).

## Passo 4 — Primeiro uso

1. Abra o seu site, clique em **Criar conta nova** e cadastre-se.
2. Preencha o nome da barbearia, o link (ex.: `barbearia-do-joao`) e o seu nome.
3. Em **Gestão**:
   - **Barbearia**: logo, cor, estilo da página do cliente (claro ou escuro), mensagem de boas-vindas, endereço, Instagram, WhatsApp, horário de funcionamento, meta do mês e o **link de agendamento com QR code**.
   - **Horários**: dias abertos e horário de cada dia, pausa pro almoço, folga semanal de cada barbeiro e bloqueio de dias ou períodos (feriado, médico). O painel e a página do cliente só oferecem horários dentro dessas regras, e o servidor confere de novo na hora de marcar.
   - **Pagamentos**: formas aceitas, chave Pix e o **sinal pra agendar** (veja abaixo).
   - **Serviços**: preços e duração.
   - **Equipe**: barbeiros (aparecem na agenda) e **Acesso ao app**: convide pelo e-mail e diga qual barbeiro da agenda a pessoa é.
     - **Barbeiro** vê a agenda (mexe só nos horários dele), os clientes e só as próprias comandas e ganhos. Não vê o caixa da barbearia, as despesas nem os ganhos dos colegas. Isso é travado no banco, não só escondido na tela.
     - **Sócio** tem o mesmo acesso do dono.
     - Quem já tinha acesso antes desta versão aparece na lista sem barbeiro ligado: escolha em "Na agenda é".
   - **Avisos de agendamento** (em Equipe, ou em Conta pro barbeiro): som, vibração e notificação quando um cliente marca pelo link. Toque em "Ativar notificação neste aparelho" em cada celular. Funciona com o app aberto ou em segundo plano; com o app totalmente fechado, ainda não.
4. Abra o link de agendamento no celular e marque um horário de teste. Ele aparece na hora na agenda do painel.

### Sinal pra agendar (Pix com confirmação manual)
- Ligado em **Gestão → Pagamentos**, o cliente que agenda pelo link vê um QR Pix e um código "copia e cola" com o valor do sinal (20%, 30%, 50% ou 100% do serviço).
- O horário fica **reservado pelo prazo escolhido** (15, 30 ou 60 minutos). Ninguém mais consegue pegar aquele horário enquanto isso.
- Na **Agenda**, a reserva aparece como "Aguardando sinal". Confira no app do seu banco e toque em **Sinal recebido**. A página do cliente mostra "Horário marcado!" sozinha.
- Se o prazo acabar sem confirmação, o horário volta a ficar livre. Se o Pix chegou atrasado, use **Recebi mesmo assim**.
- Na comanda, o sinal já aparece descontado. No fechamento do caixa, ele entra como Pix.
- Use **Testar o Pix** (mesma tela) pra conferir no app do banco se aparece o seu nome antes de ligar o sinal.
- O dinheiro cai direto na conta da barbearia, sem taxa e sem intermediário. A confirmação é manual porque o Pix comum não avisa o app; a confirmação automática exige um intermediário pago (Mercado Pago, Asaas etc.).

**Instalar no celular:** abra o site no celular e use "Adicionar à tela de início" (Safari: botão compartilhar; Chrome: menu ⋮). Ele passa a abrir como um aplicativo.

## Testar no seu computador antes de publicar (opcional)

Com o Node instalado, dentro da pasta:

```bash
npx serve .
```

Depois abra `http://localhost:3000`. Abrir o arquivo com dois cliques (`file://`) não funciona bem por causa do login.

---

## Painel do administrador (você, dono do sistema)

O endereço é o do seu site com `/admin.html` no final (ex.: `https://seusite.netlify.app/admin.html`). Salve nos favoritos. Ele não aparece em nenhum link do app.

### Virar administrador (uma vez só)
1. No Supabase, abra **SQL Editor** e rode de novo o `supabase/schema.sql` atualizado (não apaga nada).
2. Crie sua conta no app normalmente, se ainda não criou.
3. No **SQL Editor**, rode a linha abaixo trocando pelo **seu** e-mail:
   ```sql
   insert into admins (user_id) select id from auth.users where email = 'seu@email.com';
   ```
4. Abra `/admin.html` e entre com esse e-mail e senha.

### Como funciona a cobrança
- Toda barbearia nova ganha **10 dias de teste grátis** (o vencimento começa 10 dias depois do cadastro). Barbearias que já existiam mantêm o vencimento que tinham.
- Quando o vencimento passa, a barbearia tem **5 dias de tolerância** e vê um aviso no Início do app. Depois disso o acesso é **bloqueado automaticamente**: o painel mostra "Acesso suspenso" e o link de agendamento para de funcionar. Nenhum dado é apagado.
- Recebeu? Em **Registrar pagamento**, informe o valor e quantos meses. O vencimento avança e o acesso volta na hora.
- **Desativar** bloqueia na hora, independente do vencimento. **Reativar** desfaz.
- Em **Editar** você define a mensalidade de cada barbearia, ajusta o vencimento à mão e deixa anotações que só você vê. Vencimento em branco = nunca bloqueia (bom pra parceiros ou cortesia).
- O dono da barbearia não consegue mudar vencimento, mensalidade nem se reativar: isso é travado no banco.

### Pelo Supabase (se precisar ir mais fundo)
No **Table Editor**: `barbearias` (cadastro e assinatura), `pagamentos` (histórico), `membros` (quem acessa cada barbearia), `registros` (agenda, comandas, clientes, estoque, despesas e vales).

**Backup:** o plano grátis não faz backup automático. Antes de ter clientes pagando, vale migrar pro plano pago do Supabase (tem backup diário). Confira os valores atuais em supabase.com/pricing. No plano grátis o projeto também é pausado depois de um período sem uso; é só reativar no painel.

## O que ainda não tem (próximos passos)

- **Lembrete automático no WhatsApp**: hoje o app abre o WhatsApp com a mensagem pronta e a pessoa aperta enviar. O automático exige a API oficial do WhatsApp Business por um parceiro (BSP) e uma função no servidor.
- **Pix e cartão com confirmação automática** (sinal e assinatura dos clientes, e cobrança das barbearias): integração com Asaas, Pagar.me ou Mercado Pago.
- **Nota fiscal (NFS-e)**: integração com NFE.io, Focus NFe ou similar.
- **Aviso com o app fechado** (push de verdade, inclusive no iPhone): exige um servidor de notificações (Web Push) e uma função no Supabase.
- **Domínio próprio** (ex.: `agenda.suamarca.com.br`): compre o domínio (registro.br) e aponte no Netlify/Vercel em **Domains**.

## Segurança — o que já está protegido

- Cada barbearia só lê e grava os próprios dados (regras de acesso no banco, não no site).
- O cliente final, sem login, só consegue: ver o perfil público da barbearia (nome, logo, serviços, preços, barbeiros, contato e a chave Pix quando o sinal está ligado); ver quais horários estão ocupados (sem nomes); marcar um horário; consultar e desistir da própria reserva. O servidor confere se o horário está livre, se está dentro do funcionamento, se não é no passado, e calcula o valor do sinal ele mesmo.
- Cada WhatsApp só pode ter uma reserva esperando sinal por vez, pra ninguém travar a agenda com reservas falsas.
- Comissões, custos e dados de clientes nunca aparecem na página pública.
