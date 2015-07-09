# lifx-mikrotik-phone-activity-monitor (v0.0.6)

1. Connects to your MikroTik router via SSH and uses the torch monitoring tool
   to identify how many VoIP phone calls currently active.

2. Updates the LiFX WiFi LED bulb's colors to show the hue, which is randomly assigned to each phone line.
   If more than one phone is in use, it will use an average of the combined colors.

## Installation
1. Execute```bundle install```
2. Copy the 'config.example.yml' to 'config.yml' and set up the values in it

## Usage
Run the following command:
```
bundle exec ruby monitor_phone_router.rb
```


## License

Copyright (C) 2016 Tom Chapin (tchapin@gmail.com)

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program; if not, write to the Free Software Foundation, Inc.,
51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.