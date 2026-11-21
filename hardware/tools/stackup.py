"""Shared stackup switch for the routing tools.

IN2_PLANE = True : In2.Cu is a solid +3V3 plane; signals route on F.Cu and B.Cu, and every
                   +3V3 SMD pad gets a fan-out via (like GND to In1).
IN2_PLANE = False: In2.Cu is a third routing layer; +3V3 is routed as traces and In2 gets a
                   +3V3 fill after routing.
"""
IN2_PLANE = True
