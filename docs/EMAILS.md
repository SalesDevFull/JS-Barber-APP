# E-mails do Degradê (cadastro e senha nova)

Sem um serviço de envio próprio, o Supabase só manda e-mail para quem é da equipe do projeto, com poucos envios por hora. Uma barbearia nova não recebe o e-mail de confirmação e não consegue entrar. Este guia liga o envio pelo **Resend** (plano grátis: 3.000 e-mails por mês, 100 por dia) com o domínio próprio.

## 1. Domínio (Registro.br)

1. Em https://registro.br, procure o nome (ex.: `degrade.com.br`; se estiver ocupado, `degradeapp.com.br` ou `appdegrade.com.br`).
2. Registre com o seu CPF ou CNPJ. Custa cerca de R$ 40 por ano.
3. Deixe o DNS no próprio Registro.br (opção padrão). É lá que entram os registros dos passos 2 e 5.

## 2. Resend

1. Crie a conta em https://resend.com.
2. **Domains → Add domain** → digite o domínio (ex.: `degrade.com.br`).
3. O Resend mostra alguns registros (TXT do DKIM, MX e TXT do SPF). No Registro.br, abra o domínio → **DNS → Editar zona** e crie cada um exatamente como o Resend mostra (tipo, nome e valor).
4. Volte no Resend e toque em **Verify**. Pode levar de alguns minutos a algumas horas.
5. **API Keys → Create API key** com permissão "Sending access". Copie a chave (começa com `re_`). Ela é a senha do SMTP: não mande em chat nem coloque no código.

## 3. Supabase → envio pelo Resend

Supabase → projeto → **Authentication → Emails → SMTP Settings** → ligue **Enable Custom SMTP**:

| Campo | Valor |
| --- | --- |
| Sender email | `nao-responda@SEU-DOMINIO` (ex.: `nao-responda@degrade.com.br`) |
| Sender name | `Degradê` |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | a chave `re_...` do Resend |

Confira host, porta e usuário na página **SMTP** do Resend (resend.com/settings/smtp), caso tenham mudado.

Depois, em **Authentication → Rate Limits**, deixe o limite de e-mails por hora em pelo menos 30.

## 4. Textos em português

Supabase → **Authentication → Emails → Templates**:

| Modelo | Assunto | Corpo (copie o arquivo inteiro) |
| --- | --- | --- |
| Confirm signup | `Confirme seu e-mail no Degradê` | `docs/emails/confirmar-cadastro.html` |
| Reset password | `Criar uma senha nova no Degradê` | `docs/emails/recuperar-senha.html` |

Os outros modelos (Magic link, Change email, Invite) o app não usa.

## 5. Teste

1. No app, toque em **Criar conta nova** com um e-mail que não é da equipe (ex.: um Gmail).
2. O e-mail tem que chegar em português, de `Degradê`. Confira também a caixa de spam.
3. Faça o mesmo com **Esqueci a senha**.
4. Se não chegar: Resend → **Emails** mostra cada envio e o motivo de uma falha.

## Depois: app no domínio novo

Com o domínio, dá para o app sair de `jsbarberapp.vercel.app`:

1. Vercel → projeto → **Settings → Domains** → adicione `degrade.com.br` e `www.degrade.com.br`.
2. Crie no Registro.br os registros que a Vercel pedir.
3. No Supabase → **Authentication → URL Configuration**, troque a **Site URL** pelo endereço novo e adicione-o em **Redirect URLs** (mantenha o antigo também por um tempo).
4. Barbearias que já divulgaram o link antigo: ele continua funcionando enquanto o projeto na Vercel existir.
