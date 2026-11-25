# RaceBasePro Check-in

iPad aplikacija za izdavanje startnih brojeva i paketa, spojena na RACE RESULT 14 (RR14).
Potpuno odvojena od drugih projekata: **svoj Supabase projekt, svoji računi**.

**Više evenata:** u Settings → Events kreiraš event i upišeš njegove RR14 linkove (čitanje i upis).
Jedan event je aktivan i svi iPadi rade na njemu. Svaki event ima svoje sudionike, potpise, statistiku,
boje, lager majica i nazive polja. RR14 linkovi su spremljeni na serveru i nikad ne idu na iPade.

```
checkin/                      → web aplikacija (statične datoteke, ide na bilo koji HTTPS hosting)
  index.html, config.js, version.json, logo.png
supabase/migrations/…sql      → tablice, pravila pristupa, bucket za potpise (sve s prefiksom checkin_)
supabase/functions/
  checkin-sync                → svakih 30 s, za aktivni event: šalje upise u RR14, zatim čita listu sudionika
  checkin-admin               → RBP admin PIN, eventi i RR14 linkovi, postavke, odjava uređaja, "Sync from RR14 now"
  checkin-sig                 → link na potpis koji ide u RR14 (otvara privatni PNG)
```

## Stanje
Supabase projekt **Race Check IN** je postavljen (baza, funkcije, sync svakih 30 s).
Koraci ispod služe za novi projekt ili ponovnu instalaciju.

## Postavljanje (jednom, ~20 min)

1. **Novi Supabase projekt** na supabase.com (regija npr. Frankfurt ili Bahrain).
2. **Baza:** SQL Editor → zalijepi cijeli `supabase/migrations/20261125000000_checkin.sql` → Run.
3. **Funkcije:** Edge Functions → Deploy a new function → Via Editor, tri puta:
   - `checkin-sync` (kod iz `supabase/functions/checkin-sync/index.ts`)
   - `checkin-admin` (kod iz `checkin-admin/index.ts`)
   - `checkin-sig` (kod iz `checkin-sig/index.ts`)
   Svim trima **isključi "Verify JWT"**: same provjeravaju pristup (prijava, cron ključ ili token potpisa).
4. **Prijave:** Authentication → Sign In / Providers → isključi **"Allow new users to sign up"**.
   Authentication → Users → Add user: jedan ili više staff računa (email + lozinka).
5. **Sync svakih 30 s:** uključi `pg_cron` i `pg_net`, pa u SQL Editoru (zamijeni `<ref>`):
   ```sql
   select cron.schedule('checkin-sync', '30 seconds', $job$
     select net.http_post(url := 'https://<ref>.supabase.co/functions/v1/checkin-sync',
       headers := jsonb_build_object('Content-Type','application/json',
         'x-cron-key', (select cron_key from public.checkin_secret limit 1)),
       body := '{}'::jsonb, timeout_milliseconds := 25000) $job$);
   ```
   Ključ za cron stvara baza sama, nigdje ga ne treba upisivati.
6. **Web:** u `checkin/config.js` upiši Project URL i anon (publishable) ključ. Oba su javna po dizajnu.
   Uploadaj mapu `checkin/` na hosting (FTP ili server), npr. `https://tvoja-domena/checkin/`.
7. **iPad:** otvori link u Safariju → Share → Add to Home Screen → prijavi se staff računom →
   odaberi Tablet 1, 2, 3… → zupčanik → prvi put postavi RBP admin PIN.
8. **Event:** Settings → Events → New event: ime, ID i RR14 linkovi (čitanje i upis). Prvi event postaje aktivan sam.

## Ažuriranje aplikacije
Zamijeni datoteke u `checkin/` i povećaj broj u `version.json` (i `APP_VERSION` u `index.html`).
iPadi učitaju novu verziju sami unutar minute, ali tek kad nemaju otvorenog natjecatelja.

## Što ide u RR14
Nazivi polja se mijenjaju u Settings → RR14 field names. Zadano:
Signature (link), SignatureTime, PickupScope (SOLO/SELF/TEAM), CollectedBy (name of who picked up), CollectedFor, CheckinDevice,
QatariVerified, PackageIssued, PackageTime, PackageDevice, te izmjene DateOfBirth, Nation, QID,
ICEName, ICEPhone, Email, Phone. Upisi idu jednim batch pozivom (RR limit 1 poziv/s).
Ako upis ne prođe, ostaje u redu i pokušava se ponovno; stanje se vidi u Settings.

Iz RR14 se čita (zadani nazivi kolona u listi): Bib, Firstname, Lastname, Team, Sex, Nation,
DateOfBirth, AgeGroup.Name, TShirt, QID, Email, Phone, ICEName, ICEPhone.

## Za provjeriti s RR14
- Točni nazivi Additional Fields za gornje upise i ime kolone za tim i spol.
- Format datuma (Settings: DD.MM.YYYY ili YYYY-MM-DD).
