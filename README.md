**Wiwang hotel**

 20 floors 

 19 rooms per floor

 Total rooms: 380

 All rooms are empty [ no furniture ]

 *Dependencies:*
 * ox_lib: https://github.com/overextended/ox_lib
 
 *Using ox_lib for:*
 * remove and load ipls via zones [required] otherwise your game gonna crash due to high amount of rooms + portals at same location
 * elevators [optional]

**Apartments (qb-core)**

The `wiwang_apartments` resource turns the 380 real rooms into player apartments
(qb-apartments replacement): automatic room assignment, lockable door (native, ox_doorlock or
qb-doorlock), ox_target / qb-target support, stash, wardrobe, keys, knock-to-open, lobby reception,
furniture that is only rendered for rooms near you. See `wiwang_apartments/README.md`.

`tools/mlo_dump.py` dumps rooms, portals and door positions from the `.ytyp` / `.ymap` files
(this is how the room coordinates in `wiwang_apartments/shared/rooms.lua` were generated).

<img width="1911" height="1037" alt="Screenshot_2" src="https://github.com/user-attachments/assets/76695933-9ecb-4794-af57-b2ba59bf80d7" />
<img width="1909" height="1039" alt="Screenshot_1" src="https://github.com/user-attachments/assets/ccb5050c-e25a-4d5d-bf9b-7d944fc8525b" />
<img width="1908" height="1033" alt="Screenshot_5" src="https://github.com/user-attachments/assets/0a991aa3-e013-4dbb-8a6c-ce30b20f6738" />
<img width="1865" height="989" alt="Screenshot_4" src="https://github.com/user-attachments/assets/5c94fdec-25f3-47fe-9b6b-2914fdbee097" />
<img width="1878" height="937" alt="Screenshot_3" src="https://github.com/user-attachments/assets/39b4c301-c7b6-4fda-bc48-194275678cb0" />
