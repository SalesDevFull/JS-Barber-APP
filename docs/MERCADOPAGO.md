# Ligar o cartão de crédito e o Pix automático (Mercado Pago)

Você faz isto **uma vez só**, como dono do sistema. Depois, cada barbearia só aperta
**Gestão → Pagamentos → Conectar Mercado Pago** e entra com a conta dela.
O dinheiro de cada cliente cai na conta Mercado Pago da barbearia. O app não cobra comissão.

Leva uns 20 minutos. São 5 partes:

1. Atualizar o banco
2. Criar a aplicação no Mercado Pago
3. Guardar os segredos no Supabase
4. Publicar as 3 funções
5. Testar

---

## 1. Atualizar o banco

Supabase → **SQL Editor** → cole o arquivo `supabase/schema.sql` inteiro → **Run**.
Pode rodar por cima do que já existe. Nada é apagado.

## 2. Criar a aplicação no Mercado Pago

1. Entre em <https://www.mercadopago.com.br/developers/panel/app> com a **sua** conta Mercado Pago (a do dono do sistema).
2. **Criar aplicação**. Dê um nome (ex.: JS Barber APP). Quando perguntar o tipo, escolha **Pagamentos online** e a integração **Checkout Transparente** (às vezes aparece como "Checkout API" ou "Bricks"). Se perguntar se usa plataforma de e-commerce, responda **não**.
3. Dentro da aplicação, procure a parte de **OAuth / URLs de redirecionamento** (fica em "Editar aplicação" ou "Configurações") e cadastre exatamente:

   ```
   https://jhgicffdbcbomeolmwjj.supabase.co/functions/v1/mp-oauth
   ```

4. Em **Credenciais de produção**, anote o **Client ID** (é um número) e o **Client Secret**.

> ⚠️ O **Client Secret** é uma senha. Não mande no chat, não coloque no GitHub e não coloque no `config.js`. Ele vai só no próximo passo.

## 3. Guardar os segredos no Supabase

Supabase → **Edge Functions** → **Secrets** (ou Settings → Edge Functions) → adicione:

| Nome | Valor |
|---|---|
| `MP_CLIENT_ID` | o Client ID do passo 2 |
| `MP_CLIENT_SECRET` | o Client Secret do passo 2 |
| `APP_URL` | o endereço do app na Vercel, ex.: `https://js-barber-app.vercel.app` |

O `SUPABASE_URL` e a chave de serviço o Supabase já entrega pras funções sozinho.

## 4. Publicar as 3 funções

Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor**.
Repita pra cada uma, com o nome **exatamente** igual:

| Nome da função | Arquivo pra colar | "Verify JWT" |
|---|---|---|
| `mp-oauth` | `supabase/functions/mp-oauth/index.ts` | **Desligado** |
| `mp-pagar` | `supabase/functions/mp-pagar/index.ts` | pode ficar ligado |
| `mp-webhook` | `supabase/functions/mp-webhook/index.ts` | **Desligado** |

Apague o código de exemplo do editor, cole o arquivo inteiro e clique em **Deploy**.
Depois abra a função → **Settings** (ou Details) → desligue **Verify JWT** / **Enforce JWT verification**
nas duas marcadas acima. Elas recebem chamadas do Mercado Pago, que não tem login no seu app.

> Se preferir a linha de comando: `supabase functions deploy mp-oauth --no-verify-jwt`,
> `supabase functions deploy mp-pagar` e `supabase functions deploy mp-webhook --no-verify-jwt`.

O aviso de pagamento (webhook) não precisa ser cadastrado no painel do Mercado Pago:
o app manda o endereço junto com cada cobrança.

## 5. Testar

### Teste rápido com dinheiro de mentira

1. No painel do Mercado Pago (developers) → **Contas de teste** → crie uma conta **Vendedor** e uma **Comprador**.
2. No app, entre como dono de uma barbearia de teste → **Gestão → Pagamentos → Conectar Mercado Pago**.
   Na tela do Mercado Pago, entre com a **conta de teste Vendedor**. O painel deve mostrar "Conectado" e "conta de teste".
3. Ligue o **Sinal pra agendar** e salve.
4. Abra o link de agendamento numa janela anônima, marque um horário e escolha **Cartão**. Use um cartão de teste do Mercado Pago:

   | Campo | Valor |
   |---|---|
   | Número | `5031 4332 1540 6351` (Mastercard) |
   | Validade | `11/30` |
   | CVV | `123` |
   | Nome do titular | `APRO` (aprova) ou `OTHE` (recusa) |
   | CPF | `12345678909` |

   Com `APRO`, a tela vira "Horário marcado!" e a agenda do painel mostra "Sinal pago no cartão (Mercado Pago)".
   A lista completa de cartões de teste fica em "Cartões de teste" na documentação do Mercado Pago.
5. Pix de teste: escolha **Pix**, gere o código e pague com a conta de teste **Comprador**. Quando o Mercado Pago avisar, o horário confirma sozinho.

### Usando de verdade

Depois do teste, clique em **Desconectar** e conecte de novo com a conta Mercado Pago **real** da barbearia.
Cada barbearia que assinar o app faz só esse último passo.

---

## Como funciona por dentro

```
Dono  ──"Conectar"──▶ mp-oauth ──▶ Mercado Pago (dono autoriza) ──▶ mp-oauth guarda as chaves da barbearia
Cliente ──agenda──▶ reserva "aguardando sinal"
        ──cartão──▶ formulário do Mercado Pago ──token──▶ mp-pagar ──▶ cobra na conta da barbearia ──▶ aprovado = horário marcado
        ──Pix────▶ mp-pagar gera o QR ──▶ cliente paga ──▶ Mercado Pago avisa mp-webhook ──▶ horário marcado
```

- As chaves de cada barbearia ficam na tabela `mp_contas`, que nenhum navegador lê. Só as funções, com a chave de serviço.
- O valor cobrado sai sempre do banco (o sinal calculado na reserva), nunca do navegador.
- O webhook não confia no aviso: ele consulta o pagamento direto no Mercado Pago, com a conta da barbearia, antes de confirmar.
- A conexão vale 180 dias e é renovada sozinha quando falta pouco pra vencer.
- Se um pagamento for aprovado depois de a reserva cair (cliente desistiu ou o horário foi pego), o painel mostra
  **"Pagamento pra devolver"** na tela Início, com atalho pro WhatsApp do cliente.

## Se der erro

| O que aparece | O que fazer |
|---|---|
| "O Mercado Pago ainda não está configurado no servidor" | Faltam os segredos do passo 3, ou a função `mp-oauth` não foi publicada |
| Volta pro app com "Não deu pra conectar" | Confira se a URL de redirecionamento do passo 2 está exatamente igual e se o Client Secret está certo |
| O Pix online não confirma sozinho | Veja se `mp-webhook` está publicada com Verify JWT **desligado**. Os registros ficam em Edge Functions → mp-webhook → Logs |
| Cartão recusado no teste | Use o nome `APRO` no titular e a conta de teste conectada (não a real) |
