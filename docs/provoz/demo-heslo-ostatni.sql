-- Nepovinné, zavírá tutéž díru u zbylých účtů.
-- `instruktor@` a `brigadnik@` se na demu NIKDY nepřihlásily, takže je změna
-- nikoho nevyhodí. `clen@` a `clen2@` se tu SCHVÁLNĚ nemění — kluby je právě
-- používají a vyhodilo by je to z testování.
BEGIN;

UPDATE auth.users
   SET encrypted_password = extensions.crypt('zmen-si-me-42', extensions.gen_salt('bf', 10)),
       updated_at = now()
 WHERE email IN ('instruktor@test.local', 'brigadnik@test.local');

SELECT email,
       encrypted_password = extensions.crypt('Heslo1234', encrypted_password) AS stare_jeste_funguje
  FROM auth.users
 WHERE email IN ('instruktor@test.local', 'brigadnik@test.local');

-- stare_jeste_funguje musí být u obou false → COMMIT;   jinak → ROLLBACK;
