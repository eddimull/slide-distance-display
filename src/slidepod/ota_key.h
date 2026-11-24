// Public half of the firmware signing key (ECDSA P-256). The pod only
// installs an update whose SHA-256 is signed by the matching private key,
// which lives outside this repo (CI secret FIRMWARE_SIGNING_KEY). A new key
// pair needs every pod flashed once by USB with the new public key.
#pragma once

static const char SLIDEPOD_OTA_PUBLIC_KEY[] =
    "-----BEGIN PUBLIC KEY-----\n"
    "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9HNCnkE/lV6wc7eeLugzAzsu42Zt\n"
    "duKAWf46v9a465z/LnbmRLGGOGg1SI8Bo10VTKi7NI5F31ep3Hm/YuGHLg==\n"
    "-----END PUBLIC KEY-----\n";
