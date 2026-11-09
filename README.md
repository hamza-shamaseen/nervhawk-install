# NervHawk site installer

One line installs a NervHawk site on a new box:

```bash
U=https://github.com/hamza-shamaseen/nervhawk-install
curl -fsSL $U/releases/latest/download/install.sh \
  | sudo bash -s -- '<your one-use code>'
```

Your code comes from whoever runs your NervHawk fleet. It works once, for 24 hours.

## What this repository holds

Only the script and two **public** keys. There are no secrets here.

## Why it is safe to run

1. **The script checks the fleet's certificate** against a fingerprint inside your code, and only
   then sends the code.
2. **Everything it runs must be signed** by one of the two keys inside the script. Those keys did
   not come from the fleet, so a compromised fleet cannot change what the box trusts.
3. **A download that was cut off runs nothing.** The whole script runs from its last line.

You can read it first, and check it against its published checksum:

```bash
sha256sum -c install.sh.sha256
```

If it stops, it says why and how to fix it. Run the same line again: the code is not needed twice.
