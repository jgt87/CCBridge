import { useEffect, useState } from "react";
import { type NodeInstall, nodeInstallUpdate } from "@/lib/packages-card";

/** Node.js for a project's packages: without npm the packages card offers Node.js (which brings npm)
 *  first, the same install as Settings > This computer: started here, followed until it is done. */
export function useNodeInstall(initialNpm: boolean) {
  const [npm, setNpm] = useState(initialNpm);
  const [node, setNode] = useState<NodeInstall>("");
  const [nodeMessage, setNodeMessage] = useState("");
  useEffect(() => {
    if (node !== "installing") return;
    let stop = false;
    const look = () =>
      import("@/lib/api")
        .then(({ api }) => api.tools())
        .then((tools) => {
          if (stop) return;
          const u = nodeInstallUpdate(tools);
          if (!u) return;
          setNode(u.node);
          if (u.node === "done") setNpm(true);
          else setNodeMessage(u.message);
        })
        // A failed look changes nothing: the next one, 3 seconds later, asks again.
        .catch(() => undefined);
    look();
    const t = window.setInterval(look, 3000);
    return () => {
      stop = true;
      window.clearInterval(t);
    };
  }, [node]);
  const installNode = () => {
    setNode("installing");
    import("@/lib/api")
      .then(({ api }) => api.installTool("node"))
      .catch(() => {
        setNode("failed");
        setNodeMessage("The install could not be started.");
      });
  };
  return { npm, node, nodeMessage, installNode };
}
