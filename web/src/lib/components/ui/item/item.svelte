<script module>
	import { cn } from "$lib/utils.js";

	const ITEM_VARIANTS = {
  "variant": {
    "default": "bg-transparent",
    "outline": "border-border",
    "muted": "bg-muted/50"
  },
  "size": {
    "default": "gap-4 p-4",
    "sm": "gap-2.5 px-4 py-3"
  }
};
export const itemVariants = ({ variant = "default", size = "default" } = {}) =>
  cn("group/item [a]:hover:bg-accent/50 focus-visible:border-ring focus-visible:ring-ring/50 flex flex-wrap items-center rounded-md border border-transparent text-sm transition-colors duration-100 outline-none focus-visible:ring-[3px] [a]:transition-colors", ITEM_VARIANTS.variant[variant], ITEM_VARIANTS.size[size]);
</script>

<script>

	let {
		ref = $bindable(null),
		class: className,
		child,
		variant,
		size,
		...restProps
	} = $props();

	const mergedProps = $derived({
		class: cn(itemVariants({ variant, size }), className),
		"data-slot": "item",
		"data-variant": variant,
		"data-size": size,
		...restProps,
	});
</script>

{#if child}
	{@render child({ props: mergedProps })}
{:else}
	<div bind:this={ref} {...mergedProps}>
		{@render mergedProps.children?.()}
	</div>
{/if}
