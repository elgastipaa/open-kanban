export interface PortableBoardImportHeader {
  name: string;
  time_zone: string;
}

export interface PortableBoardImportHeaderChange {
  label: string;
  current: string;
  proposed: string;
}

export function compareBoardImportHeaders(
  current: PortableBoardImportHeader,
  proposed: PortableBoardImportHeader,
): PortableBoardImportHeaderChange[] {
  return [
    {
      label: "Nombre del tablero",
      current: current.name,
      proposed: proposed.name,
    },
    {
      label: "Zona horaria",
      current: current.time_zone,
      proposed: proposed.time_zone,
    },
  ];
}
